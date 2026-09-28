#  DynamicMix
#
#  Developed by Phil Meyer.
#  Based on SpiceFly SugarCube by Charles Parker - http://www.spicefly.com/
#
# This code is derived from code with the following copyright message:
# SliMP3 Server Copyright (C) 2001 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

package Plugins::DynamicMix::Plugin;

use base qw(Slim::Plugin::Base);
use strict;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Control::Request;
use Slim::Utils::OSDetect;
use Plugins::DynamicMix::Settings;
use Plugins::DynamicMix::PlayerSettings;
use Scalar::Util qw(blessed);
use DBI qw(:sql_types);
use Slim::Utils::Timers;
use URI::Escape;

use vars qw($VERSION);

my @unique=();

my $prefs = preferences('plugin.DynamicMix');

my %sugarclients=();		# Store $clients
my %playerartist=();		# Store Next Artists
my %playertrack=();			# Store Next Tracks
my %playeralbum=();			# Store Next Album

my %lastDynamicPlaylistTrack = ();
my %dynamicPlaylistActive = ();

my $port;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.DynamicMix',
	'defaultLevel' => 'DEBUG',
	'description'  => getDisplayName(),
});


sub initPlugin {
	my $class = shift;
	my $client = shift;
	$class->SUPER::initPlugin();

	$VERSION = $class->_pluginDataFor('version');
	$log->info("Initialising " . Slim::Utils::Strings::string('PLUGIN_DYNAMICMIX') . " version $VERSION");

	Plugins::DynamicMix::Settings->new;
	Plugins::DynamicMix::PlayerSettings->new;

	$port = preferences('plugin.musicip')->get('port');
	if(!defined $port) {
		$port = "10002";
		$log->debug("No Port Set for MIP, assuming the default MIP port 10002");
	}

	# Listen out for commands
	$log->debug('DynamicMix: Setting execute callback');
	Slim::Control::Request::subscribe(\&commandCallback, [['playlist']]);

	my @menu = (
		{
			# localize text where possible
			text    => Slim::Utils::Strings::string('PLUGIN_DYNAMICMIX'),
			id      => 'DynamicMixPluginMenu',
			weight  => 20,
			actions => {
				go => {
					player => 0,
					cmd    => [ 'dynamicmix', 'menu' ], 
					params => {
						activate => '1',
					},
				}
			},
			window => { titleStyle=>'settings'},
		},);

	Slim::Control::Jive::registerPluginMenu(\@menu, 'settings');
	Slim::Control::Request::addDispatch(['dynamicmix','menu'], [0, 0, 1, \&jiveDynamicMixMenu]);
	Slim::Control::Request::addDispatch(['dynamicmix','setting'], [1, 0, 1, \&jiveDynamicMixSetting]);
}

sub jiveDynamicMixMenu {
	$log->debug("Entering jiveDynamicMixMenu");

	my $request = shift;
	my $client = $request->client();

	if(!defined $client) {
		$log->warn("Client required");
		$request->setStatusNeedsClient();
		$log->debug("Exiting jiveDynamicMixSetting");
		return;
	}

	#These routines are a bit messy but we have to try and lineup
	#the value against an option from a choice list.  Choice lists
	#implementations are not clever so we have to bend to fit.

	my $style = $prefs->client($client)->get('style');
	my $styleIndex = int($style / 20);

	my $varietyIndex = $prefs->client($client)->get('variety');

	my $genreIndex;
	if (defined $prefs->client($client)->get('restrictgenre')) {
		$genreIndex = $prefs->client($client)->get('restrictgenre');
	} else {
		$genreIndex = 0;
	}

	my $recipes = Plugins::DynamicMix::PlayerSettings->getRecipesList();
	my $recipe_setting = $prefs->client($client)->get('recipe');
	my $recipeIndex = 0;
	my @recipeChoiceActions;
	for my $r (0..@$recipes-1) {
		my $rn = @$recipes[$r];
		if ($rn eq $recipe_setting) {
			$recipeIndex = $r;
		}
		push @recipeChoiceActions, {
			player => 0,
			cmd    => ['dynamicmix', 'setting', "recipe:$rn"],
		};
	}

	my $filters = Plugins::DynamicMix::PlayerSettings->getFilterList();
	my $filter_setting = $prefs->client($client)->get('filter');
	my $filterIndex = 0;
	my @filterChoiceActions;
	for my $f (0..@$filters-1) {
		my $fn = @$filters[$f];
		if ($fn eq $filter_setting) {
			$filterIndex = $f;
		}
		push @filterChoiceActions, {
			player => 0,
			cmd    => ['dynamicmix', 'setting', "filter:$fn"],
		};
	}

	my $maxRememberTracks = $prefs->client($client)->get('maxremembertracks');
	my $rememberTracksIndex = $maxRememberTracks / 5;

	my @menuItems = (
		{
			text => Slim::Utils::Strings::string('PLUGIN_DYNAMICMIX_JIVE_STYLE'),
			selectedIndex => $styleIndex + 1,
			choiceStrings => ["0", "20", "40", "60", "80", "100", "120", "140", "160", "180", "200"],
			actions => {
				do => {
					choices => [
						{ player => 0, cmd => ['dynamicmix', 'setting','style:0'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','style:20'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','style:40'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','style:60'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','style:80'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','style:100'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','style:120'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','style:140'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','style:160'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','style:180'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','style:200'], },
					],
				},
			},
		},
		{
			text => Slim::Utils::Strings::string('PLUGIN_DYNAMICMIX_JIVE_VARIETY'),
			selectedIndex => $varietyIndex + 1,
			choiceStrings => ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"],
			actions => {
				do => {
					choices => [
						{ player => 0, cmd => ['dynamicmix', 'setting','variety:0'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','variety:1'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','variety:2'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','variety:3'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','variety:4'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','variety:5'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','variety:6'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','variety:7'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','variety:8'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','variety:9'], },
					],
				},
			},
		},
		{
			text => Slim::Utils::Strings::string('PLUGIN_DYNAMICMIX_JIVE_GENRE'),
			choiceStrings => [ucfirst(Slim::Utils::Strings::string('OFF')),ucfirst(Slim::Utils::Strings::string('ON'))],
			selectedIndex => $genreIndex + 1,
			actions => {
				do => {
					choices => [
						{
							player => 0, cmd => ['dynamicmix','setting','restrictgenre:0'],
						},
						{
							player => 0, cmd => ['dynamicmix','setting','restrictgenre:1'],
						},
					],
				},
			},
		},
		{
			text => Slim::Utils::Strings::string('PLUGIN_DYNAMICMIX_JIVE_RECIPE'),
			selectedIndex => $recipeIndex + 1,
			choiceStrings => $recipes,
			actions => {
				do => {
					choices => [ @recipeChoiceActions ],
				},
			},
		},
		{
			text => Slim::Utils::Strings::string('PLUGIN_DYNAMICMIX_JIVE_FILTER'),
			selectedIndex => $filterIndex + 1,
			choiceStrings => $filters,
			actions => {
				do => {
					choices => [ @filterChoiceActions ],
				},
			},
		},
		{
			text => Slim::Utils::Strings::string('PLUGIN_DYNAMICMIX_JIVE_REMEMBER_TRACKS'),
			selectedIndex => $rememberTracksIndex + 1,
			choiceStrings => ["0", "5", "10", "15", "20"],
			actions => {
				do => {
					choices => [
						{ player => 0, cmd => ['dynamicmix', 'setting','maxremembertracks:0'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','maxremembertracks:5'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','maxremembertracks:10'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','maxremembertracks:15'], },
						{ player => 0, cmd => ['dynamicmix', 'setting','maxremembertracks:20'], },
					],
				},
			},
		},
	);

	my $cnt = 0;
	foreach my $item (@menuItems) {
		$request->setResultLoopHash('item_loop',$cnt,$item);
		$cnt++;
	}

	$request->addResult('offset',0);
	$request->addResult('count',scalar(@menuItems));
	$request->setStatusDone();
	$log->debug("Exiting jiveDynamicMixMenu");
}

########
######## SQUEEZEPLAY MENUS
########
sub jiveDynamicMixSetting {
	$log->debug("Entering jiveDynamicMixSetting");
	my $request = shift;
	my $client = $request->client();

	if(!defined $client) {
		$log->warn("Client required");
		$request->setStatusNeedsClient();
		$log->debug("Exiting jiveDynamicMixSetting");
		return;
	}

	if(defined($request->getParam('style'))) {
		$log->debug("Changing Style to: ".$request->getParam('style'));
		$prefs->client($client)->set('style', $request->getParam('style'));
	}

	if(defined($request->getParam('variety'))) {
		$log->debug("Changing Variety to: ".$request->getParam('variety'));
		$prefs->client($client)->set('variety', $request->getParam('variety'));
	}

	if(defined($request->getParam('restrictgenre'))) {
		$log->debug("Changing Restrict Genre to: ".$request->getParam('restrictgenre'));
		$prefs->client($client)->set('restrictgenre', $request->getParam('restrictgenre'));
	}

	if(defined($request->getParam('recipe'))) {
		$log->debug("Changing Recipe to: ".$request->getParam('recipe'));
		$prefs->client($client)->set('recipe', $request->getParam('recipe'));
	}

	if(defined($request->getParam('filter'))) {
		$log->debug("Changing Filter to: ".$request->getParam('filter'));
		$prefs->client($client)->set('filter', $request->getParam('filter'));
	}

	if(defined($request->getParam('maxremembertracks'))) {
		$log->debug("Changing remember tracks to: ".$request->getParam('maxremembertracks'));
		$prefs->client($client)->set('maxremembertracks', $request->getParam('maxremembertracks'));
	}

	$request->setStatusDone();
	$log->debug("Exiting jiveDynamicMixSetting");
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&commandCallback);
}

sub setMode {
	my $class  = shift;
	my $client = shift;
	my $method = shift || '';

	# Handle request to exit our mode.
	if ( $method eq 'pop' ) {
	Slim::Buttons::Common::popMode($client);
		return;
	}
}

sub getDisplayText {
	my ($client, $item) = @_;
	my $name = '';
	if($item) {
		$name = $item->{'name'};
	}
	return $name;
}

sub getOverlay {
	my ($client, $item) = @_;
	if(defined($item->{'playlist'}->{'parameters'})) {
		return [$client->symbols('rightarrow'), $client->symbols('notesymbol')];
	} else {
		return [undef, $client->symbols('notesymbol')];
	}
	if(defined($item->{'playlist'}->{'parameters'})) {
		return [$client->symbols('rightarrow'), undef];
	}
	return [undef, undef];
}

sub getFunctions {
	return {};
}

sub getDisplayName {
	return 'PLUGIN_DYNAMICMIX_ON';
}

############
###########   SB3 MENUS
############

sub commandCallback {
	my $request = shift;

	$log->debug('DynamicMix: received command: ' . $request->getRequestString());

	if ($request->source && ($request->source eq 'PLUGIN_DYNAMICMIX')) {
		return;
	}

	my $client = $request->client();
	
	if(!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}

	my $clientPrefs = $prefs->client($client);
	my $track;
	my $tracknumber;

	if (defined $clientPrefs) {
		$tracknumber = $clientPrefs->get('tracknumber');
	}

	if (!defined $tracknumber) {
		$tracknumber = 0;
		$clientPrefs->set('tracknumber', "$tracknumber");
	}

	if ($request->isCommand([['playlist'], ['newsong']])) {
		if (isDynamicPlaylistActive($client)) {
			$log->debug("DynamicMix: newsong cmd received with active Dynamic Playlist");
			return;
		}
	}
}

# Save the track into our client settings if we dont already hold a copy of it
sub SaveTrackHistory {
	my $client = shift;
	my $trackPath = shift;

	# Save current playing track as a hash into the prefs
	$trackPath = dirtyencoder($trackPath);
	$log->debug("Track after encoding: $trackPath");

	# Remembered tracks - pull into array
	my $maxRememberTracks = $prefs->client($client)->get('maxremembertracks');
	my $rememberedtracks = $prefs->client($client)->get('tracknumber');
	my $tracknumber = 1;
	my $loadtrack;
	my $temp;
	my @trackarray;

	while ($tracknumber <= $rememberedtracks) {
		$loadtrack = "track" . $tracknumber;	
		$temp = $prefs->client($client)->get("$loadtrack");
		push (@trackarray, $temp);	# Add track to array - current playing track to stop next selection matching	
		$tracknumber++;
	}

	if (grep { $_ eq $trackPath} @trackarray) {
		$log->info("Track Already in Array: $trackPath");
   } else {
   	# shuffle history tracks down one position
		my $tracknumber = $rememberedtracks;
		if ($tracknumber >= $maxRememberTracks) {
			$tracknumber = $maxRememberTracks-1;
		}
		my $maxTrackNumber = $tracknumber+1;
		
		my $savetrack;
		my $savetrackurl;
		while ($tracknumber >= 1) {
			$savetrack = "track" . ($tracknumber+1);
			$savetrackurl = $trackarray[$tracknumber-1];
			$prefs->client($client)->set("$savetrack", "$savetrackurl");
			$tracknumber--;
		}
		$trackarray[0] = $trackPath;

		# Store current track in history position 1
		$prefs->client($client)->set("track1", "$trackPath");

		$prefs->client($client)->set('tracknumber', "$maxTrackNumber");
	}

	$log->debug("Track history:");
	my $dumpindex;
	for($dumpindex=0; $dumpindex<$#trackarray+1; $dumpindex++) {
		$log->debug("$trackarray[$dumpindex]");
	}
}

sub getDisplayName {
	return 'PLUGIN_DYNAMICMIX';
}

#  Build the MIP Mix API command
sub buildMIPReq { 
	my $client = shift;
	my $seed = shift;

	$log->debug("Building MIP Mix Request using seed: $seed");

	my $mypageurl = 'http://localhost:' . $port . '/api/mix?' . $seed;

	my $styleNum = $prefs->client($client)->get('style');
	if ($styleNum) { $mypageurl = $mypageurl . '&style=' . $styleNum; }

	my $varietyNum = $prefs->client($client)->get('variety');
	if (defined $varietyNum && $varietyNum ne '') { $mypageurl = $mypageurl . '&variety=' . $varietyNum; }

	my $recipe = $prefs->client($client)->get('recipe');
	if (defined $recipe && $recipe ne '') {
		$mypageurl = $mypageurl . "&recipe=$recipe";
		$log->debug("Recipe Mixing Using: $recipe");			
	}

	my $filter = $prefs->client($client)->get('filter');
	if ($filter ne '') {
		my $myos  = Slim::Utils::OSDetect::OS();				# Fix for & signs in Genre 
		if ($myos eq 'win' || $myos eq 'mac') {
			$filter = URI::Escape::uri_escape($filter);
			$log->debug("Encoded Filter to: $filter");
			$log->debug("Operating System: $myos");
		} else {
			$filter = Slim::Utils::Misc::escape($filter);
			$log->debug("Encoded Filter to: $filter");
			$log->debug("Operating System: $myos");			
		}
		$mypageurl = $mypageurl . '&filter=' . $filter;
	}

	my $restrictgenre = $prefs->client($client)->get('restrictgenre');
	if ($restrictgenre eq "1") {
		$mypageurl = $mypageurl . '&mixgenre=1';
		$log->debug("Restrict Genre is ON");			
	}

	$log->info("Full MIP Request Built: $mypageurl");
	return $mypageurl;
}

sub SendtoMIPSync {
	my $client = shift;
	my $mypageurl = shift;

	my @test;
	my %test;
	my $element;
	my $track;
	my $url;
	my $http = LWP::UserAgent->new;

	$http->timeout(10);
	my $response = $http->get($mypageurl);
	my $content = $response->content;

	if ($response->is_success) {
		my @miparray = split(/\n/, $content);

		#dump out array
		my $dumpindex;
		$log->debug("Received Tracks From MIP\n");
		for ($dumpindex=0; $dumpindex<$#miparray+1; $dumpindex++) {
			$log->debug("@miparray[$dumpindex]");
		}

		my $changeindex;
		$log->debug("Now Encoding Array\n");
		for ($changeindex=0; $changeindex<$#miparray+1; $changeindex++)
		{
			my $enc = Slim::Utils::Unicode::encodingFromString(@miparray[$changeindex]);
			$element = Slim::Utils::Unicode::utf8decode_guess(@miparray[$changeindex], $enc);
			$log->debug("Before Internal Encoding: $element\n");

			$element = dirtyencoder($element); # NEW LINE

			$log->debug("Fully Recoded Element: $element\n");
			splice(@miparray,$changeindex,1,$element);
		}

		my $rememberedTracks = $prefs->client($client)->get('tracknumber');
		my $tracknumber = 1;
		my $loadtrack;
		my $temp;
		my @trackarray;

		while ($tracknumber <= $rememberedTracks) {
			$loadtrack = "track" . $tracknumber;
			$temp = $prefs->client($client)->get("$loadtrack");

			$log->debug("Previously played $tracknumber: $temp");

			push (@trackarray, $temp);		# Add track to array - current playing track to stop next selection matching	
			$tracknumber++;
		}

		# Check returned array against our saved array containing tracks we have played	
		my $uniqueindex;
		@test{ map { lc } @trackarray } = ();
		@unique = grep { !exists $test{lc $_} } @miparray;

		if ($#unique == -1) {
			$log->warn("No unique tracks available");
			return 0;
		} else {
			$log->info("Unique Songs: $#unique");
			for ($uniqueindex=0; $uniqueindex<$#unique+1; $uniqueindex++)
			{
				$log->debug("@unique[$uniqueindex]");
			}
		
			return 1; 
		}
	}
	else {
		$log->error("MIP Response Error " . $response->status_line);
	}

	return 0; 
}

sub isDynamicPlaylistActive {
	my $client = shift;

	my $playlist = undef;
	if(UNIVERSAL::can("Plugins::DynamicPlayList::Plugin","getCurrentPlayList")) {
		no strict 'refs';
		$playlist = eval { &{"Plugins::DynamicPlayList::Plugin::getCurrentPlayList"}($client) };
		if ($@) {
			$log->error("Error calling DynamicPlaylist plugin: $@\n");
		}
		use strict 'refs';
	}

	if (defined($playlist) && $playlist =~ /^dynamicmix/) {
		$log->debug("DynamicPlaylist is active");
		return 1;
	} else {
		$log->debug("DynamicPlaylist not active");
		return 0;
	}
}

sub getMoodsList {
	my $moods="";

	my $url = "http://localhost:$port/api/moods";
	my $ua = LWP::UserAgent->new();
	my $http = $ua->get($url);		

	if ($http) {
		$moods = join (',', split(/\n/, $http->content));
	}

	return $moods;
}

sub getDynamicPlayLists {
	my ($client) = @_;
	my @result = ();

	$log->debug("getDynamicPlayLists");

	my $moods = getMoodsList();
	$log->info("moods=$moods");

	my %dynamicMixes = (
		'dynamicmix' => {
			# Plays a MusicIP dynamic mix based on the currently playing song, or 
			# otherwise a random song.
			'id' => 'dynamicmix',
			'name' => string('PLUGIN_DYNAMICMIX'),
			'url' => 'plugins/DynamicMix/settings/basic.html?',
			'groups' => [['Songs']],
		},
		'dynamicmixartist' => {
			'id' => 'dynamicmixartist',
			'name' => string('PLUGIN_DYNAMICMIX') . ' Artist',
			'url' => 'plugins/DynamicMix/settings/basic.html?',
			'groups' => [['Artists']],
			'parameters' => {
				1 => {
					'id' => 1,
					'type' => 'artist',
					'name' => 'Choose artist',
				},
			},
		},
		'dynamicmixalbum' => {
			'id' => 'dynamicmixalbum',
			'name' => string('PLUGIN_DYNAMICMIX') . ' Album',
			'url' => 'plugins/DynamicMix/settings/basic.html?',
			'groups' => [['Albums']],
			'parameters' => {
				1 => {
					'id' => 1,
					'type' => 'album',
					'name' => 'Choose album',
				},
			},
		},
		'dynamicmixtrack' => {
			'id' => 'dynamicmixtrack',
			'name' => string('PLUGIN_DYNAMICMIX') . ' Track',
			'url' => 'plugins/DynamicMix/settings/basic.html?',
			'groups' => [['Songs']],
			'parameters' => {
				1 => {
					'id' => 1,
					'type' => 'track',
					'name' => 'Choose track',
				},
			},
		},
		'dynamicmixgenre' => {
			'id' => 'dynamicmixgenre',
			'name' => string('PLUGIN_DYNAMICMIX') . ' Genre',
			'url' => 'plugins/DynamicMix/settings/basic.html?',
			'groups' => [['Genres']],
			'parameters' => {
				1 => {
					'id' => 1,
					'type' => 'genre',
					'name' => 'Choose genre',
				},
			},
		},
		'dynamicmixmood' => {
			'id' => 'dynamicmixmood',
			'name' => string('PLUGIN_DYNAMICMIX') . ' Mood',
			'url' => 'plugins/DynamicMix/settings/basic.html?',
			'groups' => [['Playlists'], ['Songs']],
			'parameters' => {
				1 => {
					'id' => 1,
					'type' => 'list',
					'definition' => $moods,
					'name' => 'Choose mood',
				},
			},
		},
	);

	return \%dynamicMixes;
}

sub getNextDynamicPlayListTracks {
	my ($client,$dynamicplaylist,$limit,$offset,$parameters) = @_;

	my $seed = '';
	my @result = ();

	$log->info("getNextDynamicPlayListTracks offset=$offset");

	my $dynamicplaylistId = $dynamicplaylist->{id};
	$log->info("getNextDynamicPlayListTracks type $dynamicplaylistId");

	# If this isn't the first time
 	if (!$offset) {
		# This is the first time
		if ($dynamicplaylistId eq 'dynamicmixartist') {
			# Base mix on the selected artist
			$log->info("use artist for seed");

			my $artistId = $parameters->{1}->{'value'};
			$log->info("getNextDynamicPlayListTracks param 1=$artistId");
			my $artist = Slim::Schema->find('Contributor', $artistId );
			my $title = $artist->title;
			$log->info("use artist '$title' for seed");

			$seed = 'album%3d' . escape($title);
		}
		elsif ($dynamicplaylistId eq 'dynamicmixalbum') {
			# Base mix on the selected album
			$log->info("use album for seed");

			my $albumId = $parameters->{1}->{'value'};
			$log->info("getNextDynamicPlayListTracks param 1=$albumId");
			my $album = Slim::Schema->find('Album', $albumId);
			my $title = $album->title;
			$log->info("use album '$title' for seed");

			my $tracks = $album->tracks;
			my $track = $tracks->next;
			my $trackTitle = $track->title;
			$log->info("use track '$trackTitle' for album seed");

			my $trackPath = Slim::Utils::Misc::pathFromFileURL($track->url);
			$seed = 'album%3d' . escape(Slim::Utils::Unicode::utf8decode_locale($trackPath));
		}
		elsif ($dynamicplaylistId eq 'dynamicmixtrack') {
			# Base mix on the selected song
			$log->info("use song for seed");

			my $trackId = $parameters->{1}->{'value'};
			$log->info("getNextDynamicPlayListTracks param 1=$trackId");

			my $track = Slim::Schema->find('Track', $trackId);
			my $title = $track->title;
			$log->info("use song '$title' for seed");
			
			my $trackPath = Slim::Utils::Misc::pathFromFileURL($track->url);
			$seed = 'song%3d' . escape(Slim::Utils::Unicode::utf8decode_locale($trackPath));
		}
		elsif ($dynamicplaylistId eq 'dynamicmixgenre') {
			# Base mix on the selected album
			$log->info("use genre for seed");

			my $genreId = $parameters->{1}->{'value'};
			my $genre = Slim::Schema->find('Genre', $genreId);
			my $title = $genre->name;
			$log->info("use genre '$title' for seed");

			$seed = 'genre%3d' . escape($title);
		}
		elsif ($dynamicplaylistId eq 'dynamicmixmood') {
			# Base mix on a selected MIP Mood
			$log->info("use mood for seed");

			my $mood = $parameters->{1}->{'value'};
			$log->info("use mood '$mood' for seed");

			$seed = 'mood%3d' . escape($mood);
		}
		else {
			# Base mix on currently playing song
			$log->info("use current song, otherwise no seed");

			my $currentSongTrack = Slim::Player::Playlist::song($client);
			if (defined($currentSongTrack)) {
				$log->info("currently playing song url is " . $currentSongTrack->url);
				if (Slim::Music::Info::isFileURL($currentSongTrack->url)) {
					$log->info("seed on currently playing song");
	
					my $trackPath = Slim::Utils::Misc::pathFromFileURL($currentSongTrack->url);
					$seed = 'song%3d' . escape(Slim::Utils::Unicode::utf8decode_locale($trackPath));
				} else {
					$log->info("no seed - not currently playing a local song");
				}
			}
		}
	}
 	else {
 		# Base mix on last returned song for this player
 		my $song = $lastDynamicPlaylistTrack{$client};
 		$log->info("use last returned song: $song");

		my $trackPath = Slim::Utils::Misc::pathFromFileURL($song);
		$seed = 'song%3d' . escape(Slim::Utils::Unicode::utf8decode_locale($trackPath));
 	}

	my $track;
	my $mypageurl = buildMIPReq($client, $seed);
	my $diditwork = SendtoMIPSync($client, $mypageurl);

	if ($diditwork eq 1) {
		# Take First clean track from array
		my $seltrack = @unique[0];
		$log->debug("Selected Element: $seltrack");	

		$track = Slim::Schema->rs('Track')->objectForUrl($seltrack);
	}
	else {
		$log->error("SendtoMIPSync didn't work - choose a random song instead");
	}

	$#unique = -1; 					# Finished with our Unique Tracks Array, wipe it for reuse

	if (!defined $track) {
		$log->info("Choosing a random song");
		my $randomFunc = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->randomFunction();
		$track = Slim::Schema->rs('Track')->search({'audio'=>1,'remote'=>0},{ 'order_by' => \$randomFunc})->first;
	}

	if (defined $track) {
		my $trackURL = $track->url;
		$log->info("returning track URL $trackURL to Dynamic Playlist");
		$lastDynamicPlaylistTrack{$client} = $trackURL;

		my $trackPath = Slim::Utils::Misc::pathFromFileURL($trackURL);	

		SaveTrackHistory($client, $trackPath);

		# Add new song retreived from MusicIP
		push @result, $track;
	} else {
		$log->error("Couldn't find a track to play next");
	}

	return \@result; 
}


*escape = main::ISWINDOWS ? \&URI::Escape::uri_escape : \&URI::Escape::uri_escape_utf8;
sub dirtyencoder {
	my $mytitle = shift;
		$mytitle =~ s/°/%B0/g;
		$mytitle =~ s/À/%C0/g;
		$mytitle =~ s/Á/%C1/g;
		$mytitle =~ s/Â/%C2/g;
		$mytitle =~ s/Ã/%C3/g;
		$mytitle =~ s/Ä/%C4/g;
		$mytitle =~ s/Å/%C5/g;
		$mytitle =~ s/Æ/%C6/g;
		$mytitle =~ s/Ç/%C7/g;
		$mytitle =~ s/È/%C8/g;
		$mytitle =~ s/É/%C9/g;
		$mytitle =~ s/Ê/%CA/g;
		$mytitle =~ s/Ë/%CB/g;
		$mytitle =~ s/Ì/%CC/g;
		$mytitle =~ s/Í/%CD/g;
		$mytitle =~ s/Î/%CE/g;
		$mytitle =~ s/Ï/%CF/g;
		$mytitle =~ s/Ð/%D0/g;
		$mytitle =~ s/Ñ/%D1/g;
		$mytitle =~ s/Ò/%D2/g;
		$mytitle =~ s/Ó/%D3/g;
		$mytitle =~ s/Ô/%D4/g;
		$mytitle =~ s/Õ/%D5/g;
		$mytitle =~ s/Ö/%D6/g;
		$mytitle =~ s/×/%D7/g;
		$mytitle =~ s/Ø/%D8/g;
		$mytitle =~ s/Ù/%D9/g;
		$mytitle =~ s/Ú/%DA/g;
		$mytitle =~ s/Û/%DB/g;
		$mytitle =~ s/Ü/%DC/g;
		$mytitle =~ s/Ý/%DD/g;
		$mytitle =~ s/Þ/%DE/g;
		$mytitle =~ s/ß/%DF/g;
		$mytitle =~ s/à/%E0/g;
		$mytitle =~ s/á/%E1/g;
		$mytitle =~ s/â/%E2/g;
		$mytitle =~ s/ã/%E3/g;
		$mytitle =~ s/ä/%E4/g;
		$mytitle =~ s/å/%E5/g;
		$mytitle =~ s/æ/%E6/g;
		$mytitle =~ s/ç/%E7/g;
		$mytitle =~ s/è/%E8/g;
		$mytitle =~ s/é/%E9/g;
		$mytitle =~ s/ê/%EA/g;
		$mytitle =~ s/ë/%EB/g;
		$mytitle =~ s/ì/%EC/g;
		$mytitle =~ s/í/%ED/g;
		$mytitle =~ s/î/%EE/g;
		$mytitle =~ s/ï/%EF/g;
		$mytitle =~ s/ð/%F0/g;
		$mytitle =~ s/ñ/%F1/g;
		$mytitle =~ s/ò/%F2/g;
		$mytitle =~ s/ó/%F3/g;
		$mytitle =~ s/ô/%F4/g;
		$mytitle =~ s/õ/%F5/g;
		$mytitle =~ s/ö/%F6/g;
		$mytitle =~ s/÷/%F7/g;
		$mytitle =~ s/ø/%F8/g;
		$mytitle =~ s/ù/%F9/g;
		$mytitle =~ s/ú/%FA/g;
		$mytitle =~ s/û/%FB/g;
		$mytitle =~ s/ü/%FC/g;
		$mytitle =~ s/ý/%FD/g;
		$mytitle =~ s/þ/%FE/g;
		$mytitle =~ s/ÿ/%FF/g;	
		$mytitle =~ s/'/%27/g;									# replace ' sign 
		$mytitle =~ s/’/%92/g;									#  ’ sign
#Known Encoding Error; when Character is %97 strange line char
#In mySQL DB held as %96
#/SqueezeCentre/Dev-Music/My%20Music/Breakspoll%20Presents%20Vol%202%20-%20FreQ%20Nasty/18%20Fat%20Freddys%20Drop%20%96%20This%20Room.mp3
#
#ReportedFromMIP
#\SqueezeCentre\Dev-Music\My Music\Breakspoll Presents Vol 2 - FreQ Nasty\18 Fat Freddys Drop â?? This Room.mp3
#
#Recoded
#b4SCEncoding;
#\SqueezeCentre\Dev-Music\My Music\Breakspoll Presents Vol 2 - FreQ Nasty\18 Fat Freddys Drop â€“ This Room.mp3
#
#Recoded Element;
#/SqueezeCentre/Dev-Music/My%20Music/Breakspoll%20Presents%20Vol%202%20-%20FreQ%20Nasty/18%20Fat%20Freddys%20Drop%20%E2€“%20This%20Room.mp3
#
#This Fails
#
########		
# These do not require replacing and are stored natively in the database		
#		$mytitle =~ s/&/%26/g;									# replace & sign 
#		$mytitle =~ s/\+/%2B/g;									# replace + sign
#		$mytitle =~ s/\[/%5B/g;									# replace [ sign
#		$mytitle =~ s/\]/%5D/g;									# replace ] sign
########
#		$mytitle =~ s/\,/%2C/g;									# replace , sign			(DONT NEED THIS ONE?)
		$mytitle =~ s/;/%3B/g;									# replace ; sign 
		$mytitle =~ s/\\/\//g;									# Flip \ over to /
		$mytitle =~ s/ /%20/g;									# replace space char with %20
		$mytitle =~ s/\#/%23/g;									# replace space char with %20

		my $a = substr($mytitle,0,4);
		if ($a =~ m/:/i) {
			$mytitle = 'file:///' . $mytitle; 
		} else { 
			$mytitle = 'file://' . $mytitle;
		}
		
	return $mytitle;	
}

1;
__END__
