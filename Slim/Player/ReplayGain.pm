package Slim::Player::ReplayGain;


# Logitech Media Server Copyright 2001-2020 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use Scalar::Util qw(blessed);

use Slim::Music::Info;
use Slim::Player::Playlist;
use Slim::Player::ProtocolHandlers;
use Slim::Player::Source;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('server');

sub fetchGainMode {
	my $class  = shift;
	my $client = shift;
	my $song   = shift;
	my $rgmode = $prefs->client($client)->get('replayGainMode');

	my $track  = $song->currentTrack();
	my $url    = $track->url;

	# Allow plugins to override replaygain
	my $handler = $song->currentTrackHandler();
	if ( $handler->can('trackGain') ) {
		return $handler->trackGain( $client, $url );
	}

	# Mode 0 is ignore replay gain
	return undef if !$rgmode;

	if (!blessed($track) || !$track->can('replay_gain')) {

		return 0;
	}

	# shortcut: volatile tracks don't know album gain, always use track gain
	if ( Slim::Music::Info::isVolatileURL($url) ) {
		return preventClipping( $track->replay_gain(), $track->replay_peak() );
	}

	# only support track gain for remote streams
	if ( $track->remote ) {
		return preventClipping( $track->replay_gain() || $prefs->client($client)->get('remoteReplayGain'), $track->replay_peak() );
	}

	# Mode 1 is use track gain
	if ($rgmode == 1) {
		return preventClipping( $track->replay_gain(), $track->replay_peak() );
	}

	my $album = $track->album();

	if (!blessed($album) || !$album->can('replay_gain')) {

		return 0;
	}

	# Mode 2 is use album gain
	if ($rgmode == 2) {
		return preventClipping( $album->replay_gain(), $album->replay_peak() );
	}

	# Mode 3 is determine dynamically whether to use album or track
	if (defined $album->replay_gain() && ($class->trackAlbumMatch($client, -1) || $class->trackAlbumMatch($client, 1))) {

		return preventClipping( $album->replay_gain(), $album->replay_peak() );
	}

	return preventClipping( $track->replay_gain(), $track->replay_peak() );
}

sub findTracksByIndex {
	my $class  = shift;
	my $client = shift;
	my $offset = shift;

	my $current_index = Slim::Player::Source::streamingSongIndex($client);
	my $compare_index = Slim::Player::Source::streamingSongIndex($client) + $offset;

	my $count         = Slim::Player::Playlist::count($client);
	my $repeat        = Slim::Player::Playlist::repeat($client);

	# if no songs in the playlist, abort
	return unless $count;

	# only one song in the playlist, abort
	if ( $count == 1 || $repeat == 1 ) {
		return;
	}

	# Check the case where the track to compare against is
	# at the other end of the playlist.
	if ($compare_index < 0) {
		# No repeat means we don't match around the edges
		return 0 unless $repeat;

		return $class->trackAlbumMatch($client, $count - 1);
	}
	elsif ($compare_index >= $count) {
		# No repeat means we don't match around the edges
		return 0 unless $repeat;

		return $class->trackAlbumMatch($client, -$current_index);
	}

	# Get the track objects
	my $current_url   = Slim::Player::Playlist::track($client, $current_index);
	my $current_track = Slim::Schema->objectForUrl({ 'url' => $current_url, 'create' => 1, 'readTags' => 1 });

	my $compare_url   = Slim::Player::Playlist::track($client, $compare_index);
	my $compare_track = Slim::Schema->objectForUrl({ 'url' => $compare_url, 'create' => 1, 'readTags' => 1 });

	return ($current_track, $compare_track);
}

# Based on code from James Sutula's Dynamic Transition Updater plugin,
# this method determines whether tracks at a given offset from each
# other in the playlist are similarly adjacent within the same album.
sub trackAlbumMatch {
	my $class  = shift;
	my $client = shift;
	my $offset = shift;

	my ($current_track, $compare_track) = $class->findTracksByIndex($client, $offset);
	return if (!$current_track || !$compare_track);

	if (!blessed($current_track) || !blessed($compare_track)) {

		logError("Couldn't find object for track: [$current_track] or [$compare_track] !");

		return 0;
	}

	if (!$current_track->can('album') || !$compare_track->can('album')) {

		logError("Couldn't a find valid object for track: [$current_track] or [$compare_track] !");

		return 0;
	}

	# For remote tracks, get metadata from the protocol handler
	if ( $current_track->remote ) {
		if ( !$compare_track->remote ) {
			# Other track is not remote, fail
			return;
		}

		my $current_meta = {};
		my $compare_meta = {};

		my $current_handler = Slim::Player::ProtocolHandlers->handlerForURL( $current_track->url );
		my $compare_handler = Slim::Player::ProtocolHandlers->handlerForURL( $compare_track->url );

		if ( $current_handler && $current_handler->can('getMetadataFor') ) {
			$current_meta = $current_handler->getMetadataFor( $client, $current_track->url );
		}

		if ( $compare_handler && $compare_handler->can('getMetadataFor') ) {
			$compare_meta = $compare_handler->getMetadataFor( $client, $compare_track->url );
		}

		if (   $current_meta->{album}
			&& $compare_meta->{album}
			&& $current_meta->{album} eq $compare_meta->{album}
		) {
			# Album metadata matches
			return 1;
		}
		else {
			return;
		}
	}

	# Check for album and tracknum matches as expected
	if ($compare_track->albumid && $current_track->albumid &&
		($compare_track->albumid == $current_track->albumid) &&
		defined $current_track->tracknum && defined $compare_track->tracknum &&
		(($current_track->tracknum + $offset) == $compare_track->tracknum)) {

		return 1;
	}

	return 0;
}

# Identify whether the sample rates match between two tracks in a
# client playlist. This is modelled after the trackAlbumMatch function
# above.
sub trackSampleRateMatch {
	my $class  = shift;
	my $client = shift;
	my $offset = shift;

	my ($current_track, $compare_track) = $class->findTracksByIndex($client, $offset);
	return if (!$current_track || !$compare_track);

	if (!blessed($current_track) || !blessed($compare_track)) {

		logError("Couldn't find object for track: [$current_track] or [$compare_track] !");

		return 0;
	}

	if (!$current_track->can('samplerate') || !$compare_track->can('samplerate')) {

		logError("Couldn't a find valid object for track: [$current_track] or [$compare_track] !");

		return 0;
	}

	# For remote tracks, get metadata from the protocol handler
	if ( $current_track->remote ) {
	  if ( !$compare_track->remote ) {
			# Other track is not remote, fail
			return;
		}

		my $current_meta = {};
		my $compare_meta = {};

		my $current_handler = Slim::Player::ProtocolHandlers->handlerForURL( $current_track->url );
		my $compare_handler = Slim::Player::ProtocolHandlers->handlerForURL( $compare_track->url );

		if ( $current_handler && $current_handler->can('getMetadataFor') ) {
			$current_meta = $current_handler->getMetadataFor( $client, $current_track->url );
		}

		if ( $compare_handler && $compare_handler->can('getMetadataFor') ) {
			$compare_meta = $compare_handler->getMetadataFor( $client, $compare_track->url );
		}

		if (   $current_meta->{samplerate}
			&& $compare_meta->{samplerate}
			&& $current_meta->{samplerate} eq $compare_meta->{samplerate}
		) {
			# Sample rate metadata matches
			return 1;
		}
		else {
			return;
		}
	}

	# Check sample rates match
	my $compare_rate = $compare_track->samplerate;
	my $current_rate = $current_track->samplerate;
	if ($compare_rate && $current_rate &&
		($compare_rate == $current_rate)) {

		return 1;
	}

	return 0;
}

# Bug 5119
# Reduce the gain value if necessary to avoid clipping
sub preventClipping {
	my ( $gain, $peak ) = @_;

	if ( defined $peak && defined $gain && $peak > 0 ) {
		my $noclip = -20 * ( log($peak) / log(10) );
		if ( $noclip < $gain ) {
			return $noclip;
		}
	}

	return $gain;
}

1;

__END__
