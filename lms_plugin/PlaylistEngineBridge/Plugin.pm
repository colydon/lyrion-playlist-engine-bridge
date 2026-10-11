package Plugins::PlaylistEngineBridge::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);
use URI::Escape qw(uri_escape_utf8);
use POSIX ();
use Slim::Control::Jive;
use Slim::Control::Request;
use Slim::Web::HTTP;
use Slim::Web::Pages;
use Slim::Utils::Log;
use Slim::Utils::Timers;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.playlistenginebridge',
	defaultLevel => 'INFO',
	description  => 'Playlist Engine Bridge',
});

my %DEFAULT_CONFIG = (
	engine_base_url => 'http://127.0.0.1:8787',
	api_token       => '',
	menu_title      => 'Custom Playlists',
	quick_launch_playlist => '',
	quick_launch_title    => '',
	suppress_dstm_when_engine_active => 1,
);

# --- Don't Stop The Music (DSTM) -------------------------------------------------
# LMS roept disableDSTM() aan voor plugins die <canConflictWithDSTM>1</canConflictWithDSTM>
# in hun install.xml hebben. Zolang de engine een sessie heeft voor een speler zeggen we
# "nee": DSTM blijft er dan van af. Zodra de sessie weg is, doet DSTM weer gewoon mee.
# De sessielijst wordt door een hulpproces opgehaald (nooit blokkerend voor LMS) en in
# een klein cachebestand gezet dat disableDSTM() razendsnel kan lezen.
my $SESSION_CACHE         = '/tmp/playlist_engine_bridge_sessions.json';
my $SESSION_CACHE_MAX_AGE = 120;   # seconden; ouder betekent: engine onbereikbaar -> DSTM weer toestaan
my $SESSION_POLL_SECONDS  = 20;
my $SESSION_POLL_START    = 5;

my $COMMAND_DEBUG_FLAG = '/tmp/playlist_engine_bridge_debug';   # aanwezig bestand = playlist-commando's loggen

my $suppress_dstm = 1;
my $managed_key   = '';
my $cache_stale   = 0;


sub getDisplayName {
	return 'Custom Playlists';
}


sub initPlugin {
	my $class = shift;

	my $config = _load_config();
	my $quick_launch_playlist = $config->{quick_launch_playlist} || '';
	my $quick_launch_title = $config->{quick_launch_title} || ($quick_launch_playlist ? 'Start ' . $quick_launch_playlist : '');
	my $browse_item = {
		text   => $config->{menu_title},
		weight => 79,
		id     => 'playlistenginebridge',
		window => { titleStyle => 'mymusic' },
		actions => {
			go => {
				cmd => ['playlistenginebridge', 'browse'],
			},
		},
	};

	if ($quick_launch_playlist) {
		my $quick_launch_item = {
			text   => $quick_launch_title,
			weight => 78,
			id     => 'playlistenginebridge_quickstart_mymusic',
			window => { titleStyle => 'mymusic' },
			actions => {
				go => {
					player => 0,
					cmd    => ['playlistenginebridge', 'start'],
					params => {
						playlist => $quick_launch_playlist,
					},
				},
			},
		};

		Slim::Control::Jive::registerPluginMenu([$quick_launch_item], 'myMusic');
	}

	if ($quick_launch_playlist) {
		my @homeItems = (
			{
				text   => $quick_launch_title,
				weight => 15,
				id     => 'playlistenginebridge_quickstart',
				window => { titleStyle => 'hm_myMusic' },
				actions => {
					go => {
						player => 0,
						cmd    => ['playlistenginebridge', 'start'],
						params => {
							playlist => $quick_launch_playlist,
						},
					},
				},
			},
		);

		Slim::Control::Jive::registerPluginMenu(\@homeItems, 'home');
		_register_material_home_extra($quick_launch_playlist, $quick_launch_title);
	}

	Slim::Control::Jive::registerPluginMenu([$browse_item], 'myMusic');
	Slim::Control::Request::addDispatch(['playlistenginebridge', 'browse'], [1, 0, 1, \&cliBrowseHandler]);
	Slim::Control::Request::addDispatch(['playlistenginebridge', 'start'], [1, 1, 1, \&cliStartHandler]);
	Slim::Control::Request::addDispatch(['playlistenginebridge', 'stop'], [1, 0, 1, \&cliStopHandler]);

	$suppress_dstm = $config->{suppress_dstm_when_engine_active} ? 1 : 0;
	if ($suppress_dstm) {
		$log->info('DSTM wordt onderdrukt zolang de engine een sessie heeft voor een speler.');
	}
	Slim::Control::Request::subscribe(\&logPlaylistCommand, [['playlist']]);
	_startSessionPolling();

	$class->SUPER::initPlugin();
}


sub webPages {
	my $class = shift;
	my $config = _load_config();
	Slim::Web::Pages->addPageFunction('playlistenginebridge_list\.html', \&handleWebList);
	Slim::Web::Pages->addPageLinks('browse', { 'Custom Playlists' => 'plugins/PlaylistEngineBridge/playlistenginebridge_list.html' });

	if ($config->{quick_launch_playlist}) {
		my $title = $config->{quick_launch_title} || ('Start ' . $config->{quick_launch_playlist});
		my $target = 'plugins/PlaylistEngineBridge/playlistenginebridge_list.html?action=start&playlist=' . uri_escape_utf8($config->{quick_launch_playlist});
		Slim::Web::Pages->addPageLinks('home', { $title => $target });
		Slim::Web::Pages->addPageLinks('browse', { $title => $target });
	}
}


sub _register_material_home_extra {
	my ($playlist, $title) = @_;

	return unless $playlist;
	return unless eval { require Plugins::MaterialSkin::Plugin; 1 };
	return unless Plugins::MaterialSkin::Plugin->can('registerHomeExtra');

	Plugins::MaterialSkin::Plugin->registerHomeExtra('playlistenginebridge_material_quickstart', {
		title       => $title,
		subtitle    => 'Custom Playlists',
		needsPlayer => 1,
		handler     => sub {
			my ($client, $callback, $args) = @_;

			my @items = ({
				text    => $title,
				style   => 'itemplay',
				actions => {
					go => {
						player => 0,
						cmd    => ['playlistenginebridge', 'start'],
						params => {
							playlist => $playlist,
						},
					},
				},
			});

			$callback->(\@items);
		},
	});

	Plugins::MaterialSkin::Plugin->signalHomeExtraUpdate()
		if Plugins::MaterialSkin::Plugin->can('signalHomeExtraUpdate');
}


sub cliBrowseHandler {
	my $request = shift;
	my $client  = $request->client();

	if (!$client) {
		$request->setStatusNeedsClient();
		return;
	}

	my $response = _engine_request('GET', '/api/playlists');
	if (!$response->{ok}) {
		_render_error_menu($request, $response->{error});
		return;
	}

	my @items;
	push @items, {
		text    => 'Stop current custom playlist',
		style   => 'itemplay',
		actions => {
			go => {
				player => 0,
				cmd    => ['playlistenginebridge', 'stop'],
			},
		},
	};

	for my $playlist (@{$response->{items} || []}) {
		my $title = $playlist->{title} || $playlist->{id};
		if ($playlist->{description}) {
			$title .= ' - ' . $playlist->{description};
		}

		push @items, {
			text    => $title,
			style   => 'itemplay',
			actions => {
				go => {
					player => 0,
					cmd    => ['playlistenginebridge', 'start'],
					params => {
						playlist => $playlist->{id},
					},
				},
			},
		};
	}

	_render_menu($request, \@items);
}


sub cliStartHandler {
	my $request  = shift;
	my $client   = $request->client();
	my $playlist = $request->getParam('playlist');

	if (!$client) {
		$request->setStatusNeedsClient();
		return;
	}

	if (!$playlist) {
		_render_error_menu($request, 'Missing playlist id');
		return;
	}

	_schedule_engine_request('POST', '/api/start', {
		playlist  => $playlist,
		player_id => $client->id(),
	}, 'start ' . $playlist . ' on ' . $client->name());

	my @items = (
		{
			text  => 'Starting ' . $playlist . ' on ' . $client->name(),
			style => 'itemNoAction',
		},
		{
			text    => 'Back to custom playlists',
			actions => {
				go => {
					player => 0,
					cmd    => ['playlistenginebridge', 'browse'],
				},
			},
		},
	);

	_render_menu($request, \@items);
}


sub cliStopHandler {
	my $request = shift;
	my $client  = $request->client();

	if (!$client) {
		$request->setStatusNeedsClient();
		return;
	}

	_schedule_engine_request('POST', '/api/stop', {
		player_id => $client->id(),
	}, 'stop session on ' . $client->name());

	my @items = (
		{
			text  => 'Stopping custom playlist session on ' . $client->name(),
			style => 'itemNoAction',
		},
		{
			text    => 'Back to custom playlists',
			actions => {
				go => {
					player => 0,
					cmd    => ['playlistenginebridge', 'browse'],
				},
			},
		},
	);

	_render_menu($request, \@items);
}


sub handleWebList {
	my ($client, $params) = @_;

	if (!$client) {
		$params->{engine_error} = 'No player selected in LMS.';
		return Slim::Web::HTTP::filltemplatefile('plugins/PlaylistEngineBridge/playlistenginebridge_list.html', $params);
	}

	my $action = $params->{action} || '';
	my $playlist = $params->{playlist} || '';

	if ($action eq 'start' && $playlist) {
		_schedule_engine_request('POST', '/api/start', {
			playlist  => $playlist,
			player_id => $client->id(),
		}, 'start ' . $playlist . ' on ' . $client->name());

		$params->{engine_success} = 'Starting ' . $playlist . ' on ' . $client->name();
	}
	elsif ($action eq 'stop') {
		_schedule_engine_request('POST', '/api/stop', {
			player_id => $client->id(),
		}, 'stop session on ' . $client->name());

		$params->{engine_success} = 'Stopping custom playlist session on ' . $client->name();
	}

	my $response = _engine_request('GET', '/api/playlists');
	if ($response->{ok}) {
		$params->{engine_playlists} = $response->{items} || [];
	}
	else {
		$params->{engine_playlists} = [];
		$params->{engine_error} ||= $response->{error};
	}

	$params->{engine_player_name} = $client->name;
	$params->{engine_player_id} = $client->id;

	return Slim::Web::HTTP::filltemplatefile('plugins/PlaylistEngineBridge/playlistenginebridge_list.html', $params);
}


sub _render_error_menu {
	my ($request, $message) = @_;
	my @items = (
		{
			text  => 'Playlist Engine error: ' . ($message || 'unknown error'),
			style => 'itemNoAction',
		},
	);
	_render_menu($request, \@items);
}


sub _render_menu {
	my ($request, $items) = @_;
	my $count = 0;

	for my $item (@{$items}) {
		$request->setResultLoopHash('item_loop', $count, $item);
		$count++;
	}

	$request->addResult('offset', 0);
	$request->addResult('count', scalar(@{$items}));
	$request->setStatusDone();
}


sub _engine_request {
	my ($method, $path, $payload, $timeout) = @_;
	my $config = _load_config();
	my $url    = $config->{engine_base_url} . $path;
	my $http   = HTTP::Tiny->new(timeout => ($timeout || 60));
	my %headers = ('Content-Type' => 'application/json');

	if ($config->{api_token}) {
		$headers{'X-API-Key'} = $config->{api_token};
	}

	my %options = (headers => \%headers);
	if ($method eq 'POST') {
		$options{content} = encode_json($payload || {});
	}

	my $response = $http->request($method, $url, \%options);
	if (!$response->{success}) {
		my $message = $response->{status} . ' ' . ($response->{reason} || 'request failed');
		$log->warn('Engine request failed for ' . $url . ': ' . $message);
		return {
			ok    => 0,
			error => 'HTTP request failed: ' . $message,
		};
	}

	if (!$response->{content}) {
		return { ok => 1 };
	}

	my $decoded = eval { decode_json($response->{content}) };
	if ($@) {
		$log->warn('Could not decode engine response: ' . $@);
		return {
			ok    => 0,
			error => 'Could not decode engine response',
		};
	}

	if (exists $decoded->{ok} && !$decoded->{ok}) {
		return {
			ok    => 0,
			error => $decoded->{error} || 'Unknown engine error',
		};
	}

	$decoded->{ok} = 1 if !exists $decoded->{ok};
	return $decoded;
}


sub _schedule_engine_request {
	my ($method, $path, $payload, $description) = @_;
	my $pid = fork();
	if (!defined $pid) {
		$log->warn('Could not fork scheduled engine request for ' . ($description || $path));
		return;
	}

	return if $pid;

	select(undef, undef, undef, 0.25);
	my $response = eval { _engine_request($method, $path, $payload) };
	if ($@) {
		$log->warn('Scheduled engine request failed for ' . ($description || $path) . ': ' . $@);
		exit 0;
	}
	if (!$response->{ok}) {
		$log->warn('Scheduled engine request returned an error for ' . ($description || $path) . ': ' . ($response->{error} || 'unknown error'));
	}
	exit 0;
}


sub disableDSTM {
	my ($class, $client) = @_;

	return 0 unless $suppress_dstm;
	return 0 unless $client;

	my $managed = $class->isEngineManaged($client) ? 1 : 0;

	if (-e $COMMAND_DEBUG_FLAG) {
		$log->info(sprintf(
			'DSTM-vraag voor %s (%s): engine actief = %s',
			(eval { $client->name } || '?'),
			(eval { $client->id } || '?'),
			($managed ? 'ja, DSTM blijft eraf' : 'nee, DSTM mag bijspringen'),
		));
	}

	return $managed;
}


sub isEngineManaged {
	my ($class, $client) = @_;

	my $sessions = _readSessionCache();
	return 0 unless $sessions && ref $sessions->{players} eq 'ARRAY' && scalar @{ $sessions->{players} };

	my %managed = map { lc($_) => 1 } grep { defined $_ && $_ ne '' } @{ $sessions->{players} };

	# Groepsleden en groepsmeesters allebei accepteren.
	for my $candidate ($client, (eval { $client->master })) {
		next unless $candidate && ref $candidate;
		my $id = eval { $candidate->id };
		return 1 if $id && $managed{ lc $id };
	}

	return 0;
}


sub _startSessionPolling {
	return unless $suppress_dstm;
	Slim::Utils::Timers::setTimer(undef, time() + $SESSION_POLL_START, \&pollEngineSessions);
}


sub pollEngineSessions {
	_refreshSessionCache() if $suppress_dstm;
	_reportManagedPlayers();
	Slim::Utils::Timers::setTimer(undef, time() + $SESSION_POLL_SECONDS, \&pollEngineSessions);
}


sub _reportManagedPlayers {
	my $sessions = _readSessionCache();
	my $stale    = $sessions ? 0 : 1;
	my $key      = join(',', ($sessions && ref $sessions->{players} eq 'ARRAY') ? sort @{ $sessions->{players} } : ());

	if ($stale && !$cache_stale) {
		$log->warn('Geen verse sessielijst van de playlist-engine; DSTM mag weer bijspringen.');
	}
	elsif (!$stale && $cache_stale) {
		$log->info('Sessielijst van de playlist-engine is weer actueel.');
	}
	$cache_stale = $stale;

	return if $key eq $managed_key;
	$managed_key = $key;

	$log->info('Engine-sessies: ' . ($key || '(geen)'));
}


# Haalt de sessielijst op in een hulpproces. Mislukt dat, dan blijft het cachebestand
# staan en veroudert het vanzelf, zodat DSTM na $SESSION_CACHE_MAX_AGE weer gewoon werkt.
sub _refreshSessionCache {
	my $pid = fork();
	if (!defined $pid) {
		$log->warn('Kon geen hulpproces starten voor sessieverversing.');
		return;
	}

	return if $pid;

	select(undef, undef, undef, 0.05);

	my $response = eval { _engine_request('GET', '/api/sessions', undef, 5) };

	if ($response && $response->{ok} && ref $response->{sessions} eq 'ARRAY') {
		my $players = [ map { $_->{player_id} } grep { ref $_ eq 'HASH' && $_->{player_id} } @{ $response->{sessions} } ];
		_writeSessionCache($players);
	}

	# _exit(): geen END-blokken of DESTROY-rommel in een hulpproces van LMS.
	POSIX::_exit(0);
}


sub _writeSessionCache {
	my ($players) = @_;
	my $path    = $SESSION_CACHE . '.' . $$;
	my $payload = encode_json({ players => $players, updated => time() });

	my $handle;
	if (!open($handle, '>', $path)) {
		$log->warn('Kon ' . $path . ' niet schrijven: ' . $!);
		return;
	}

	print {$handle} $payload;
	close $handle;

	if (!rename($path, $SESSION_CACHE)) {
		$log->warn('Kon ' . $path . ' niet verplaatsen naar ' . $SESSION_CACHE . ': ' . $!);
		unlink $path;
	}
}


sub _readSessionCache {
	my @info = stat($SESSION_CACHE);
	return undef unless @info && $info[9] && (time() - $info[9]) <= $SESSION_CACHE_MAX_AGE;

	open(my $handle, '<', $SESSION_CACHE) or return undef;
	my $raw = do { local $/ = undef; <$handle> };
	close $handle;

	my $decoded = eval { decode_json($raw) };
	return (ref $decoded eq 'HASH') ? $decoded : undef;
}


# Diagnose: alleen actief als /tmp/playlist_engine_bridge_debug bestaat. Zo kan er
# zonder LMS-herstart (of code-wijziging) meegelogd worden wie de queue aanpast.
sub logPlaylistCommand {
	my $request = shift;

	# Zonder markeerbestand doet deze functie niets (geen ruis in het log).
	return unless -e $COMMAND_DEBUG_FLAG;

	my $client = eval { $request->client };
	my @params;

	for my $name (qw(_what _listref listref _index _url)) {
		my $value = eval { $request->getParam($name) };
		next unless defined $value;

		if (ref $value eq 'ARRAY') {
			$value = sprintf('[%s, n=%d]', ($value->[0] // '?'), scalar @$value);
		}

		push @params, $name . '=' . (ref $value ? '(ref)' : $value);
	}

	$log->info(sprintf(
		'playlist-commando %s%s, bron=%s%s',
		(eval { $request->getRequestString } || '?'),
		(@params ? ' [' . join(' ', @params) . ']' : ''),
		(eval { $request->source } || 'onbekend'),
		($client ? ', speler=' . $client->name . ' (' . $client->id . ')' : ''),
	));
}


sub _load_config {
	my $config_path = catfile(dirname(__FILE__), 'bridge_config.json');
	my %config = %DEFAULT_CONFIG;

	if (-e $config_path) {
		if (open my $handle, '<', $config_path) {
			local $/ = undef;
			my $raw = <$handle>;
			close $handle;
			my $decoded = eval { decode_json($raw) };
			if ($decoded && ref $decoded eq 'HASH') {
				%config = (%config, %{$decoded});
			}
			elsif ($@) {
				$log->warn('Could not parse bridge config: ' . $@);
			}
		}
		else {
			$log->warn('Could not open bridge config file ' . $config_path);
		}
	}

	return \%config;
}


1;