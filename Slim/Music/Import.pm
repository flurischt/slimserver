package Slim::Music::Import;

# SlimServer Copyright (c) 2001-2006  Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

=head1 NAME

Slim::Music::Import

=head1 SYNOPSIS

	my $class = 'Plugins::iTunes::Importer';

	# Make an importer available for use.
	Slim::Music::Import->addImporter($class);

	# Turn the importer on or off
	Slim::Music::Import->useImporter($class, Slim::Utils::Prefs::get('itunes'));

	# Start a serial scan of all importers.
	Slim::Music::Import->runScan;
	Slim::Music::Import->runScanPostProcessing;

	if (Slim::Music::Import->stillScanning) {
		...
	}

=head1 DESCRIPTION

This class controls the actual running of the Importers as defined by a
caller. The process is serial, and is run via the L<scanner.pl> program.

=head1 METHODS

=cut

use strict;

use base qw(Class::Data::Inheritable);

use Config;
use FindBin qw($Bin);
use Proc::Background;
use Scalar::Util qw(blessed);

use Slim::Music::Info;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;

{
	my $class = __PACKAGE__;

	for my $accessor (qw(cleanupDatabase scanPlaylistsOnly useFolderImporter scanningProcess)) {

		$class->mk_classdata($accessor);
	}
}

# Total of how many file scanners are running
our %importsRunning = ();
our %Importers      = ();

my $folderScanClass = 'Slim::Music::MusicFolderScan';

=head2 launchScan( \%args )

Launch the external (forked) scanning process.

\%args can include any of the arguments the scanning process can accept.

=cut

sub launchScan {
	my ($class, $args) = @_;

	# Pass along the prefsfile & logfile flags to the scanner.
	if (defined $::prefsfile && -r $::prefsfile) {
		$args->{"prefsfile=$::prefsfile"} = 1;
	}

	if (defined $::logfile) {
		$args->{"logfile=$::logfile"} = 1;
	}

	if (defined $::noLogTimestamp ) {
		$args->{'noLogTimestamp'} = 1;
	}

	# Ugh - need real logging via Log::Log4perl
	# Hardcode the list of debugging options that the scanner accepts.
	my @debug = qw(d_info d_server d_import d_parse d_parse d_sql d_startup d_itunes d_moodlogic d_musicmagic);

	# Search the main namespace hash to see if they're defined.
	for my $opt (@debug) {

		no strict 'refs';
		my $check = '::' . $opt;

		$args->{$opt} = 1 if $$check;
	}

	# Add in the various importer flags
	for my $importer (qw(itunes musicmagic moodlogic)) {

		if (Slim::Utils::Prefs::get($importer)) {

			$args->{$importer} = 1;
		}
	}

	# Set scanner priority.  Use the current server priority unless 
	# scannerPriority has been specified.

	my $scannerPriority = Slim::Utils::Prefs::get("scannerPriority");

	unless (defined $scannerPriority && $scannerPriority ne "") {
		$scannerPriority = Slim::Utils::Misc::getPriority();
	}

	if (defined $scannerPriority && $scannerPriority ne "") {
		$args->{"priority=$scannerPriority"} = 1;
	}

	my @scanArgs = map { "--$_" } keys %{$args};

	my $command  = "$Bin/scanner.pl";

	# Check for different scanner types.
	if (Slim::Utils::OSDetect::OS() eq 'win' && -x "$Bin/scanner.exe") {

		$command  = "$Bin/scanner.exe";

	} elsif (Slim::Utils::OSDetect::isDebian() && -x '/usr/sbin/slimserver-scanner') {

		$command  = '/usr/sbin/slimserver-scanner';
	}

	# Bug: 3530 - use the same version of perl we were started with.
	if ($Config{'perlpath'} && -x $Config{'perlpath'} && $command !~ /\.exe$/) {

		unshift @scanArgs, $command;
		$command  = $Config{'perlpath'};
	}

	$class->scanningProcess(
		Proc::Background->new($command, @scanArgs)
	);

	# Set a timer to check on the scanning process.
	Slim::Utils::Timers::setTimer(0, (Time::HiRes::time() + 30), \&checkScanningStatus);

	return 1;
}

=head2 checkScanningStatus( )

If we're still scanning, start a timer process to notify any subscribers of a
'rescan done' status.

=cut

sub checkScanningStatus {
	my $class = shift || __PACKAGE__;

	Slim::Utils::Timers::killTimers(0, \&checkScanningStatus);

	# Run again if we're still scanning.
	if ($class->stillScanning) {

		Slim::Utils::Timers::setTimer(0, (Time::HiRes::time() + 60), \&checkScanningStatus);

	} else {

		# Clear caches, like the vaObj, etc after scanning has been finished.
		Slim::Schema->wipeCaches;

		Slim::Control::Request::notifyFromArray(undef, [qw(rescan done)]);
	}
}

=head2 lastScanTime()

Returns the last time the user ran a scan, or 0.

=cut

sub lastScanTime {
	my $class = shift;
	my $name  = shift || 'lastRescanTime';

	my $last  = Slim::Schema->single('MetaInformation', { 'name' => $name });

	return blessed($last) ? $last->value : 0;
}

=head2 setLastScanTime()

Set the last scan time.

=cut

sub setLastScanTime {
	my $class = shift;
	my $name  = shift || 'lastRescanTime';
	my $value = shift || time;

	eval { Slim::Schema->txn_do(sub {

		my $last = Slim::Schema->rs('MetaInformation')->find_or_create({
			'name' => $name
		});

		$last->value($value);
		$last->update;
	}) };
}

=head2 runScan( )

Start a scan of all used importers.

This is called by the scanner.pl helper program.

=cut

sub runScan {
	my $class  = shift;

	# If we are scanning a music folder, do that first - as we'll gather
	# the most information from files that way and subsequent importers
	# need to do less work.
	if ($Importers{$folderScanClass} && !$class->scanPlaylistsOnly) {

		$class->runImporter($folderScanClass);

		$class->useFolderImporter(1);
	}

	# Check Import scanners
	for my $importer (keys %Importers) {

		# Don't rescan the music folder again.
		if ($importer eq $folderScanClass) {
			next;
		}

		# These importers all implement 'playlist only' scanning.
		# See bug: 1892
		if ($class->scanPlaylistsOnly && !$Importers{$importer}->{'playlistOnly'}) {

			$::d_import && msg("Import: Skipping [$importer] - it doesn't implement playlistOnly scanning!\n");

			next;
		}

		$class->runImporter($importer);
	}

	$class->scanPlaylistsOnly(0);

	return 1;
}

=head2 runScanPostProcessing( )

This is called by the scanner.pl helper program.

Run the post-scan processing. This includes merging Various Artists albums,
finding artwork, cleaning stale db entries, and optimizing the database.

=cut

sub runScanPostProcessing {
	my $class  = shift;

	# Auto-identify VA/Compilation albums
	$::d_import && msg("Import: Starting mergeVariousArtistsAlbums().\n");

	$importsRunning{'mergeVariousAlbums'} = Time::HiRes::time();

	Slim::Schema->mergeVariousArtistsAlbums;

	# Post-process artwork, so we can use title formats, and use a generic
	# image to speed up artwork loading.
	$::d_import && msg("Import: Starting findArtwork().\n");

	$importsRunning{'findArtwork'} = Time::HiRes::time();

	Slim::Music::Artwork->findArtwork;

	# Remove and dangling references.
	if ($class->cleanupDatabase) {

		# Don't re-enter
		$class->cleanupDatabase(0);

		$importsRunning{'cleanupStaleEntries'} = Time::HiRes::time();

		Slim::Schema->cleanupStaleTrackEntries;
	}

	# Reset
	$class->useFolderImporter(0);

	# Always run an optimization pass at the end of our scan.
	$::d_import && msg("Import: Starting Database optimization.\n");

	$importsRunning{'dbOptimize'} = Time::HiRes::time();

	Slim::Schema->optimizeDB;

	$class->endImporter('dbOptimize');

	$::d_import && msg("Import: Finished background scanning.\n");

	return 1;
}

=head2 deleteImporter( $importer )

Removes a importer from the list of available importers.

=cut

sub deleteImporter {
	my ($class, $importer) = @_;

	delete $Importers{$importer};
}

=head2 addImporter( $importer, \%params )

Add an importer to the system. Valid params are:

=over 4

=item * use => 1 | 0

Shortcut to use / not use an importer. Same functionality as L<useImporter>.

=item * setup => \&addGroups

Code reference to the web setup function.

=item * reset => \&code

Code reference to reset the state of the importer.

=item * playlistOnly => 1 | 0

True if the importer supports scanning playlists only.

=item * mixer => \&mixerFunction

Generate a mix using criteria from the client's parentParams or
modeParamStack.

=item * mixerlink => \&mixerlink

Generate an HTML link for invoking the mixer.

=back

=cut

sub addImporter {
	my ($class, $importer, $params) = @_;

	$Importers{$importer} = $params;

	$::d_import && msgf("Import: Adding %s Scan\n", $importer);
}

=head2 runImporter( $importer )

Calls the importer's startScan() method, and adds a start time to the list of
running importers.

=cut

sub runImporter {
	my ($class, $importer) = @_;

	if ($Importers{$importer}->{'use'}) {

		$importsRunning{$importer} = Time::HiRes::time();

		# rescan each enabled Import, or scan the newly enabled Import
		$::d_import && msgf("Import: Starting %s scan\n", $importer);

		$importer->startScan;

		return 1;
	}

	return 0;
}

=head2 countImporters( )

Returns a count of all added and available importers. Excludes
L<Slim::Music::MusicFolderScan>, as it is our base importer.

=cut

sub countImporters {
	my $class = shift;
	my $count = 0;

	for my $importer (keys %Importers) {
		
		# Don't count Folder Scan for this since we use this as a test to see if any other importers are in use
		if ($Importers{$importer}->{'use'} && $importer ne $folderScanClass) {

			$count++;
		}
	}

	return $count;
}

=head2 resetSetupGroups( )

Run the 'setup' function as defined by each importer.

=cut

sub resetSetupGroups {
	my $class = shift;

	$class->_walkImporterListForFunction('setup');
}

=head2 resetImporters( )

Run the 'reset' function as defined by each importer.

=cut

sub resetImporters {
	my $class = shift;

	$class->_walkImporterListForFunction('reset');
}

sub _walkImporterListForFunction {
	my $class    = shift;
	my $function = shift;

	for my $importer (keys %Importers) {

		if (defined $Importers{$importer}->{$function}) {
			&{$Importers{$importer}->{$function}};
		}
	}
}

=head2 importers( )

Return a hash reference to the list of added importers.

=cut

sub importers {
	my $class = shift;

	return \%Importers;
}

=head2 useImporter( $importer, $trueOrFalse )

Tell the server to use / not use a previously added importer.

=cut

sub useImporter {
	my ($class, $importer, $newValue) = @_;

	if (!$importer) {
		return 0;
	}

	if (defined $newValue && exists $Importers{$importer}) {

		$Importers{$importer}->{'use'} = $newValue;

	} else {

		return exists $Importers{$importer} ? $Importers{$importer} : 0;
	}
}

=head2 endImporter( $importer )

Removes the given importer from the running importers list.

=cut

sub endImporter {
	my ($class, $importer) = @_;

	if (exists $importsRunning{$importer}) { 

		$::d_import && msgf("Import: Completed %s Scan in %s seconds.\n",
			$importer, int(Time::HiRes::time() - $importsRunning{$importer})
		);

		delete $importsRunning{$importer};

		return 1;
	}

	return 0;
}

=head2 stillScanning( )

Returns true if the server is still scanning your library. False otherwise.

=cut

sub stillScanning {
	my $class    = shift;
	my $imports  = scalar keys %importsRunning;

	# NB: Some plugins call this, but haven't updated to use class based calling.
	if (!$class) {

		$class = __PACKAGE__;

		msg("Warning: Caller needs to updated to use ->stillScanning, not ::stillScanning()!\n");
		bt();
	}

	# Check and see if there is a flag in the database, and the process is alive.
	my $scanRS   = Slim::Schema->single('MetaInformation', { 'name' => 'isScanning' });
	my $scanning = blessed($scanRS) ? $scanRS->value : 0;

	my $running  = blessed($class->scanningProcess) && $class->scanningProcess->alive ? 1 : 0;

	if ($running && $scanning) {
		return 1;
	}

	return 0;
}

=head1 SEE ALSO

L<Slim::Music::MusicFolderScan>

L<Slim::Music::PlaylistFolderScan>

L<Plugins::iTunes::Importer>

L<Plugins::MusicMagic::Importer>

L<Plugins::MoodLogic::Importer>

L<Proc::Background>

=cut

1;

__END__
