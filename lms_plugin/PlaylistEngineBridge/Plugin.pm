package Plugins::PlaylistEngineBridge::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);
use URI::Escape qw(uri_escape_utf8);
use Slim::Control::Jive;
use Slim::Control::Request;
use Slim::Web::HTTP;
use Slim::Web::Pages;
use Slim::Utils::Log;

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
);


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
	my ($method, $path, $payload) = @_;
	my $config = _load_config();
	my $url    = $config->{engine_base_url} . $path;
	my $http   = HTTP::Tiny->new(timeout => 60);
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