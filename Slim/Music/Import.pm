package Slim::Music::Import;

# SlimServer Copyright (c) 2001-2004 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use Slim::Utils::Misc;
use Slim::Music::iTunes;
use Slim::Music::MoodLogic;
use Slim::Music::MusicMagic;
use Slim::Music::MusicFolderScan;

# background scanning and cache prefilling of music information to speed up UI...

# Total of how many file scanners are running
my %importsRunning;
my %importers;

# Force a rescan of all the importers (TODO: Make importers pluggable)
sub startScan {
	# Only start if the database has been initialized
	return if (!defined(Slim::Music::Info::getCurrentDataStore()));
		
	$::d_info && msg("Clearing ID3 cache\n");
	Slim::Music::Info::clearCache();
	
	$::d_info && msg("Starting background folder, itunes, moodlogic and musicmagic scanning.\n");
	Slim::Music::MusicFolderScan::startScan();
	Slim::Music::iTunes::startScan();
	Slim::Music::MoodLogic::startScan();
	Slim::Music::MusicMagic::startScan();
}

sub startup {
	$::d_info && msg("Starting itunes/moodlogic/musicmagic background scanners.\n");

	Slim::Music::iTunes::checker();
	Slim::Music::MoodLogic::checker();
	Slim::Music::MusicMagic::checker();
}

sub startImport {
	my $import = shift;
	$::d_info && msg("Adding $import Scan\n");
	$importsRunning{$import} = Time::HiRes::time();
}

sub addImporter {
	my $import = shift;

	$importers{$import} = 1;
}

sub countImporters {
	return scalar keys %importers;
}

sub endImport {
	my $import = shift;
	if (exists $importsRunning{$import}) { 
		$::d_info && msg("Completing $import Scan in ".(Time::HiRes::time() - $importsRunning{$import})." seconds\n");
		delete $importsRunning{$import};
	}

	if (scalar keys %importsRunning == 0) {
		Slim::Music::Info::clearStaleCacheEntries();
		Slim::Music::Info::reBuildCaches();
		$::d_info && msg("Finished background scanning.\n");
		Slim::Music::Info::saveDBCache();
	}
}

sub stillScanning {
	my $imports = scalar keys %importsRunning;
	$::d_info && msg("Scanning with $imports import plugins\n");
	return $imports;
}


1;
__END__

