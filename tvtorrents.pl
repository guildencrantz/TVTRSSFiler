#!/usr/bin/perl -w

use strict;

use File::Slurp;
use Getopt::Long;
use HTML::Entities;
use LWP::Simple;
use Sys::Syslog qw( :DEFAULT );
use XML::RSS::Parser::Lite;

my %allowed_extensions = (
	'avi' => 1,
	'mp4' => 1,
	'mkv' => 1,
);

openlog('tvtorrents.pl', 'pid', 'local0') or die $!;
syslog('info', 'START');

my $tvtDigest;
my $tvtHash;
my @tags;
my $interval;
my $delay;
my $include;
my $exclude;
my $torrentDirectory     = '.tvtorrents/torrents/';
my $downloadDirectory    = '.tvtorrents/links/';
my $destinationDirectory = './TV/';
my $help;
GetOptions(
	'digest|d=s'   => \$tvtDigest,
	'hash|s=s'     => \$tvtHash,
	'tag|t=s@'     => \@tags,
	'interval|i=s' => \$interval,
	'delay|y=s'    => \$delay,
	'include|n=s'  => \$include,
	'exclude|e=s'  => \$exclude,
	'torrents=s'   => \$torrentDirectory,
	'download=s'   => \$downloadDirectory,
	'dest=s'       => \$destinationDirectory,
	'help|h'       => \$help
);

if ($help) {
	&help();
	exit;
}

unless ($tvtDigest) {
	print "You must specify your tvtorrents RSS Digest!\n\n";
	&help();
	die;
}
unless ($tvtHash) {
	print "You must specify your tvtorrents RSS Hash!\n\n";
	&help();
	die;
}

my @rssFeeds = sprintf(
	"http://www.tvtorrents.com/mydownloadRSS?digest=%s&hash=%s",
	$tvtDigest,
	$tvtHash
);

my $baseTagURL = sprintf(
	'http://www.tvtorrents.com/mytaggedRSS?digest=%s&hash=%s%s%s%s%s',
	$tvtDigest,
	$tvtHash,
	$interval ? "&interval=$interval" : '',
	$delay    ? "&delay=$delay"       : '',
	$include  ? "&include=$include"   : '',
	$exclude  ? "&exclude=$exclude"   : '',
);

if (@tags) {
	foreach my $tag (@tags) {
		push @rssFeeds, sprintf('%s&tag=%s', $baseTagURL, $tag);
	}
}
else {
	push @rssFeeds, $baseTagURL;
}

my $ua = LWP::UserAgent->new;
$ua->agent('Mozilla/5.0 TVTRSSFiler');

my $newShow = 0;
foreach my $feed (@rssFeeds) {
	my $alwaysDownload = $feed =~ /mydownloadRSS/;

	foreach my $response ($ua->get($feed)) {
		unless ($response->is_success) {
			syslog(
				'err',
				sprintf 'Unable to retrieve "%s": \n%s\n%s',
						$feed,
						$response->status_line,
						$response->decoded_content
			);
		}
		my $rp = new XML::RSS::Parser::Lite;
		$rp->parse($response->decoded_content);

		for (my $i = 0; $i < $rp->count(); $i++) {
			my $show = $rp->get($i);
			syslog('debug', $show->get('description'));

			my %showDetails;
			foreach(split(/; ?/, decode_entities($show->get('description')))) {
				/(.+?):\s*(.+?)\s*$/;
				$showDetails{$1} = $2;
			}

			my $filename = $showDetails{'Filename'};

			my $showName = $showDetails{'Show Name'};
			$showName =~ s/ /_/g;

			my $extension = ($filename =~ m/([^.]+)$/)[0];
			if($alwaysDownload || $allowed_extensions{$extension}) {
				if(!$alwaysDownload && -e "$downloadDirectory$filename") {
					syslog(
						'info',
						"file ($filename) was found in the links directory"
					);
				} else {
					my $showTitle = $showDetails{'Show Title'};
					# Replace spaces in titles with underscores
					$showTitle =~ s/\s/_/g;

					# Replace slashes in titles with dashes, so they aren't
					# treated as directories when trying to create links.
					$showTitle =~ s|/|-|g;

					if($showDetails{'Episode'} =~ /^\d$/) {
						$showDetails{'Episode'} = sprintf(
							"%02d",
							$showDetails{'Episode'}
						);
					}
					my $episode = sprintf(
						"S%02dE%s",
						$showDetails{'Season'},
						$showDetails{'Episode'}
					);
					my $destinationName = sprintf "%s.%s.", $showName, $episode;

					my @downloadedEps =
						<$destinationDirectory$showName/*$episode*>;

					if(!$alwaysDownload && $#downloadedEps >= 0) {
						syslog(
							'info',
							"This episode ($destinationName) was already "
							. "downloaded, will skip it."
						);
					} elsif($alwaysDownload && $#downloadedEps == 1) {
						link("$downloadDirectory$filename", $downloadedEps[0]);
						&downloadTorrent(
							url       => $show->get('url'),
							filename  => $filename,
							useragent => $ua
						);
					} elsif($alwaysDownload && $#downloadedEps > 1) {
						syslog(
							'err',
							'There is more than one file matching episode '
							. "($destinationName) already downloaded, you'll "
							. 'have to fix that before we can reseed '
							. 'automatically.'
						);
					} else {
						$destinationName .= "$showTitle.$extension";

						if(-e "$destinationDirectory$showName") {
							syslog('info', "show directory was found");
							syslog(
								'info',
								"The episode ($destinationName) needs to be "
								. 'downloaded!'
							);
						} else	{
							syslog(
								'info',
								"file ($filename) was not found, nor was the "
								. 'show directory ('
								. "$destinationDirectory$showName), will "
								. 'create the show directory and download the '
								. 'torrent.'
							);
							mkdir "$destinationDirectory$showName" or
								syslog(
									'err',
									"Unable to create directory '"
									. "$destinationDirectory$showName'"
								);
						}

						if(&downloadTorrent(
							url       => $show->get('url'),
							filename  => $filename,
							useragent => $ua
						)) {
							syslog('info',
								'Torrent was saved, waiting for the rtorrent '
								. 'to create the download file, will then '
								. 'create link to destination'
							);

							while(! -e "$downloadDirectory$filename") {
								syslog(
									'debug',
									"Waiting for '$downloadDirectory$filename' "
									. 'to be created'
								);
								sleep(1);
							}
							link(
								"$downloadDirectory$filename",
								"$destinationDirectory$showName/$destinationName"
							) or syslog(
								'err',
								'Unable to create link "'
								. "$downloadDirectory$filename\" to \""
								. "$destinationDirectory$showName/$destinationName"
								. "\": $!\n"
							);

							$newShow = 1;

							syslog(
								'info',
								'rtorrent has created the download file and '
								. 'the link has been created.'
							);
						}
					}
				}
			} else {
				syslog(
					'info',
					"File ($filename) has extension '$extension', which is not "
					. 'in ' . join(', ', keys %allowed_extensions)
				);
			}
		}
	}
}

if ($newShow) {
	get("http://localhost:32400/library/sections/3/refresh");
}

syslog('info', 'ENDED');
closelog;

sub downloadTorrent {
	my %args = @_;
	$args{url} ||
		die "The required parameter 'url' was not passed to downloadTorrent!";
	$args{filename} ||
		die "The required parameter 'filename' was not passed to downloadTorrent!";
	$args{useragent} ||
		die "The required parameter 'useragent' was not passed to downloadTorrent!";

	my $response = $args{useragent}->get(decode_entities($args{url}));

	if($response->is_success) {
		my $torrentFile = sprintf(
			"%s%s.torrent",
			$torrentDirectory,
			$args{filename}
		);
		open(TORRENT, ">$torrentFile") ||
			die "Unable to open torrent file $torrentFile for writing: $!";
		print TORRENT $response->content;
		close TORRENT;
	} else {
		syslog('err', sprintf "Unable to retrieve torrent at '%s'\n%s\n%s.",
		                      $args{url},
							  $response->status_line,
							  $response->decoded_content );
	}

	return $response->is_success;
}

sub help() {
	print <<EOH
Usage: $0 --digest --hash [--tag --interval --torrents --download --dest]
	-d
	--digest	Your TVTorrents.com RSS digest (login to TVTorrents and go to your RSS feed page--http://tvtorrents.com/loggedin/my/rss.do--and copy the "digest=" section of the URL from the "Recent torrents" link).

	-s
	--hash		Your TVTorrents.com RSS hash (login to TVTorrents and go to your RSS feed page--http://tvtorrents.com/loggedin/my/rss.do--and copy the "hash=" section of the URL from the "Recent torrents" link).

	-t
	--tag		The tag you want to download. You can specify multiple tags by including this flag multiple times. If no tag is specified your favorites will be downloaded.

	-i
	--interval	The interval over which the torrents requested should come from (reference: http://tvtorrents.com/loggedin/faq_answer.do?id=104)

	-y
	--delay		Specifies a delay before including an item, i.e. 30+minutes.

	-n
	--include	Regular Expression defining what MUST BE in the item for it to be included (reference: http://tvtorrents.com/loggedin/faq_answer.do?id=122)

	-e
	--exclude	Regular Expression defining what MUST NOT BE in the item for it to be included (reference: http://tvtorrents.com/loggedin/faq_answer.do?id=122)

	--torrents  Path to directory where the torrent files should be downloaded to.
				Default=.tvtorrents/links/

	--download	Path to directory where rtorrent will download the actual files
				Default=.tvtorrents/torrents/

	--dest		Path to directory where the link targets should be.
				Default=./TV/

	-h
	--help		Print this message and exit.
EOH
}

# vim: set ai noet :
