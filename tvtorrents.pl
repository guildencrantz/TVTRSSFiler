#!/usr/bin/perl -w

use strict;
use Sys::Syslog qw( :DEFAULT );
use LWP::Simple;
use XML::RSS::Parser::Lite;
use HTML::Entities;
use File::Slurp;

my $downloadDirectory = '/nas/.rtorrent/links/';
my $torrentDirectory = '/nas/.rtorrent/torrents/';
my $destinationDirectory = '/nas/TV/';

openlog('tvtorrents.pl', 'pid', 'local0');
syslog('info', 'START');

my @rssFeeds = "http://www.tvtorrents.com/mydownloadRSS?";
push @rssFeeds, "http://www.tvtorrents.com/RssServlet?fav=true&interval=7+days";
foreach my $rss (@rssFeeds) {
	my $alwaysDownload = $rss =~ /mydownloadRSS/;

	foreach my $xml (get($rss)) {
		my $rp = new XML::RSS::Parser::Lite;
		$rp->parse($xml);

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

			if($alwaysDownload || $filename =~ /avi$/) {
				if(!$alwaysDownload && -e "$downloadDirectory$filename") {
					syslog('info', "file ($filename) was found in the links directory");
				} else {
					my $showTitle = $showDetails{'Show Title'};
					$showTitle =~ s/ /_/g;

					if($showDetails{'Episode'} =~ /^\d$/) {
						$showDetails{'Episode'} = sprintf "%02d", $showDetails{'Episode'};
					}
					my $episode = sprintf "S%02dE%s", $showDetails{'Season'}, $showDetails{'Episode'};
					my $destinationName = sprintf "%s.%s.", $showName, $episode;

					my @downloadedEps = <$destinationDirectory$showName/*$episode*>;

					if(!$alwaysDownload && $#downloadedEps >= 0) {
						syslog('info', "This episode ($destinationName) was already downloaded, will skip it.");
					} elsif($alwaysDownload && $#downloadedEps == 1) {
						link("$downloadDirectory$filename", $downloadedEps[0]); 
						&downloadTorrent(url=>$show->get('url'), filename=>$filename);
					} elsif($alwaysDownload && $#downloadedEps > 1) {
						syslog('err', "There is more than one file matching episode ($destinationName) already downloaded, you'll have to fix that before we can reseed automatically.");
					} else {
						$destinationName .= $showTitle . ".avi";

						if(-e "$destinationDirectory$showName") {
							syslog('info', "show directory was found");
							syslog('info', "The episode ($destinationName) needs to be downloaded!");
						} else	{
							syslog('info', "file ($filename) was not found, nor was the show directory ($destinationDirectory$showName), will create the show directory and download the torrent.");
							mkdir "$destinationDirectory$showName" or syslog('err', "Unable to create directory '$destinationDirectory$showName'");
						}

						if(&downloadTorrent(url=>$show->get('url'), filename=>$filename)) {
							syslog('info', "Torrent was saved, waiting for the rtorrent to create the download file, will then create link to destination");

							while(!-e "$downloadDirectory$filename") {
								syslog('debug', "Waiting for '$downloadDirectory$filename' to be created");
								sleep(1);
							}
							link("$downloadDirectory$filename", "$destinationDirectory$showName/$destinationName"); 

							syslog('info', "rtorrent has created the download file and the link has been created.");
						}
					}
				}
			} else {
				syslog('info', "File ($filename) is not an avi");
			}
		}
	}
}

syslog('info', 'ENDED');
closelog;

sub downloadTorrent {
	my %args = @_;
	$args{url} || die "The required parameter 'url' was not passed to downloadTorrent!";
	$args{filename} || die "The required parameter 'filename' was not passed to downloadTorrent!";

	my $torrent = get(decode_entities($args{url}));

	if(defined $torrent) {
		open(TORRENT, sprintf ">%s%s.torrent", $torrentDirectory, $args{filename});
		print TORRENT $torrent;
		close TORRENT;
	} else {
		syslog('err', "Unable to retrieve torrent.");
	}

	return defined $torrent;
}
