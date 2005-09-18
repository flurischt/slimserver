package Slim::Hardware::VFD;

# $Id$

# SlimServer Copyright (c) 2001-2004 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;
use Slim::Utils::Misc;
use Slim::Display::Display;

my %vfdCommand = ();

# these codes identify the operation to 
# perform on each byte of data sent.
my $vfdCodeCmd  = pack 'B8', '00000010';       
my $vfdCodeChar = pack 'B8', '00000011'; 

# vfd.pl initiliazion:  Builds %vfdCommand, an associative array containing the 
# packed codes for all the noritake VFD commands
$vfdCommand{"CFF"}		= pack 'B8', "00001100";
$vfdCommand{"CUR"}		= pack 'B8', "00001110";

$vfdCommand{"HOME"} 	= pack 'B8', "00000010";
$vfdCommand{"HOME2"} 	= pack 'B8', "11000000";

$vfdCommand{"INCSC"} 	= pack 'B8', "00000110";

my @vfdBright = ( (pack 'B8', "00000011"), # 0%
				  (pack 'B8', "00000011"), # 25%
				  (pack 'B8', "00000010"), # 50%
				  (pack 'B8', "00000001"), # 75%
				  (pack 'B8', "00000000")); # 100%

my @vfdBrightFutaba = ( (pack 'B8', "00111011"), # 0%
				   (pack 'B8', "00111011"), # 25%
				   (pack 'B8', "00111010"), # 50%
				   (pack 'B8', "00111001"), # 75%
				   (pack 'B8', "00111000")); # 100%

my $noritakeBrightPrelude = 
			   $vfdCodeCmd .  (pack 'B8', "00110011") . 
			   $vfdCodeCmd .  (pack 'B8', "00000000") .
			   $vfdCodeCmd .  (pack 'B8', "00110000") .
			   $vfdCodeChar;

my $vfdReset = $vfdCodeCmd . $vfdCommand{"INCSC"} . $vfdCodeCmd . $vfdCommand{"HOME"};

$Slim::Hardware::VFD::MAXBRIGHTNESS = 4;

my $spaces = ' ' x 40;

my %symbolmap = (
	'katakana' => {
		'notesymbol' => chr(0x0e),
		'rightarrow' => chr(0x0f),
		'leftvbar' => chr(0x10),
		'rightvbar' => chr(0x18),
		'hardspace' => chr(0x20),
		'solidblock' => chr(0x1f),
	},
	'latin1' => {
		'rightarrow' => chr(0x1a),
		'hardspace' => chr(0x20),
		'solidblock' => chr(0x1f),
	},
	'european' => {
		'rightarrow' => chr(0x7e),
		'hardspace' => chr(0x20),
		'solidblock' => chr(0x1f),
	}
);

# depricated, use the Slim::Display functions
sub symbol {
	return Slim::Display::Display::symbol(@_);
}

sub lineLength {
	return Slim::Display::Display::lineLength(@_);
}

sub splitString {
	return Slim::Display::Display::splitString(@_);
}

sub subString {
	return Slim::Display::Display::subString(@_);
}
	

#
# Given the address of the character to edit, followed by an array of eight numbers specifying
# the bitmask of the character, caches the codes needed to create the specified character.
#
my %vfdcustomchars;

sub setCustomChar {
	my($charname, @rows)=@_;
	
	die unless ((@rows) == 8); 
	$vfdcustomchars{$charname} = \@rows;
}

sub isCustomChar {
	my $charname = shift;

	return exists($vfdcustomchars{$charname});
}

my %customChars;

# Map of alternatives if custom character space exhaused
my %gracefulmap = (
    'slash'      => '/',
	'backslash'  => '\\',
	'islash'     => '\\',
	'ibackslash' => '/',
	'Ztop'       => chr(0x1f),
	'Zbottom'    => '/',
	'leftvbar'   => '|',
	'rightvbar'  => '|',
);


sub vfdUpdate {
	my $client = shift;
	my $line1  = shift; 
	my $line2  = shift;

	my %customUsed;
	my %newCustom;
	my $cur = -1;
	my $pos;

	# convert to the VFD char set
	my $lang = $client->vfdmodel;
	if (!$lang) { 
		$lang = 'katakana';
	} else {
		$lang =~ s/[^-]*-(.*)/$1/;
	}

	$::d_ui && msg("vfdUpdate $lang\nline1: $line1\nline2: $line2\n\n");
	
	my $brightness = $client->brightness();

	if (!defined($line1)) { $line1 = $spaces };
	if (!defined($line2)) { $line2 = $spaces };

	if (defined($brightness) && ($brightness == 0)) {
		$line1 = $spaces;
		$line2 = $spaces;
	} 
	
	my $line;

	my $cursorchar = Slim::Display::Display::symbol('cursorpos');

	my $i = 0;

	foreach my $curline ($line1, $line2) {
		my $linepos = 0;

		# Always force the character displays into latin1
		# XXX - does this work for the european and katakana VFDs?
		#
		# If this isn't here - selecting a song with non-latin1 chars
		# will cause the server to crash.

		# Fix for bug 1294 - Windows "smart" apostrophe to a normal one.
		# For whatever reason, utf8toLatin1() doesn't convert this to
		# a ' - \x{2019}, so do it manually. Otherwise the server will
		# crash. We should also investigate Encode::compat - for 5.6.x
		my $wasUTF8;
		if ($] > 5.007) {
			$wasUTF8 = Encode::_utf8_off($curline);
		}

		$curline =~ s/\xe2\x80\x99/'/g;

		if ($] > 5.007 and $wasUTF8) {
			Encode::_utf8_on($curline);
		}

		$curline = Slim::Utils::Unicode::utf8toLatin1($curline);

		while (1) {
			# if we're done with the line, break;
			if ($linepos >= length($curline)) {
				last;
			}

			# get the next character
			my $scan = substr($curline, $linepos);

			# if this is a cursor position token, remember the location and go on
			if ($scan =~ /^$cursorchar/) {
				$cur = $i;
				$linepos += length($cursorchar);
				redo;
			# if this is a custom character, process it
			} elsif ($scan =~ /^\x1F([^\x1F]+)\x1F/) {
				$linepos += length("\x1F". $1 . "\x1F");
				# is it one of our existing symbols?
				if ($symbolmap{$lang} && $symbolmap{$lang}{$1}) {
					$line .= $symbolmap{$lang}{$1};
				} else {
					# must be a custom character, check if we have it already mapped
					if (exists($customChars{$client}{$1})) {
						my $cchar = $customChars{$client}{$1};
						$line .= $cchar;
						$customUsed{$cchar} = $1;
					# remember the new custom character and use temporary
					} else {
						$line .= "\x1F" . $1 . "\x1F";
						$newCustom{$1} = 1;
					}
				}
				$i++;
			# it must just be a regular character, whew...
			} else {
				$line .= substr($scan, 0, 1);
				$linepos++;
				$i++
			}	
		}
	}
	# Find out which custom chars we need to add, and which we can discard
	my $usedCustom = scalar keys(%customUsed);
	my $nextChr = chr(0);
	foreach my $custom (keys %newCustom) {
		my $encodedCustom = "\x1F" . $custom . "\x1F";
		if ($usedCustom < 8) { # Room to add this one
			while(defined $customUsed{$nextChr}) {
				$nextChr = chr(ord($nextChr)+1);
			}
			# Insert code into line, replacing temporaries
			$line =~ s/$encodedCustom/$nextChr/g;
			# Forget previous custom at this code
			foreach my $prevCustom (keys(%{$customChars{$client}})) {
				delete $customChars{$client}{$prevCustom} if($customChars{$client}{$prevCustom} eq $nextChr);
			}
			# Record new custom and code
			$customChars{$client}{$custom} = $nextChr;
			$customUsed{$nextChr} = $custom;
			$usedCustom++;
			$nextChr = chr(ord($nextChr)+1);
		} else { # No space left; use a space
		    $::d_ui && msg( "no space left:" . $custom . "\n") ;
		    if ($gracefulmap{$custom}) {
				$::d_ui && msg( "graceful: " . $custom . " -> " . $gracefulmap{$custom} . "\n" );
				$line =~ s/$encodedCustom/$gracefulmap{$custom}/g;
		    } else {
				$::d_ui && msg("ungraceful\n");
				$line =~ s/$encodedCustom/ /g;
		    }
			delete $newCustom{$custom};
		}
	}

	if ($lang eq 'european') {
		# why can't we all just get along?
		$line =~ tr{\x1f\x92\xa1\xa2\xa3\xa4\xa5\xa6\xa8\xa9\xab\xad\xaf \xbb\xbf \xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf \xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xdb\xdc\xdd\xde\xdf \xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef \xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff}
				   {\xff\x27\x21\x63\x4c\x6f\x59\x7c\x22\x63\x22\x2d\x2d \x22\xeb \xb4\xb3\xd3\xb2\xf1\xf3\xce\xc9\xb8\xb7\xd6\xf7\xf0\xb0\xd0\xb1 \xcb\xde\xaf\xbf\xdf\xcf\xef\x78\x30\xb6\xb5\xf4\xd4\x59\xfb\xe2 \xa4\xa3\xc3\xa2\xe1\xc3\xbe\xc9\xa8\xa7\xc6\xe7\xe0\xa0\xc0\xa1 \xab\xee\xaf\xbf\xdf\xcf\xef\x2f\xbd\xa6\xa5\xe4\xf5\xac\xfb\xcc};
	} elsif ($lang eq 'katakana'){
		# translate iso8859-1 to vfd charset
		$line =~ tr{\x1f\x92\x0e\x0f\x5c\x70\x7e\x7f\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xdb\xdc\xdd\xde\xdf\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff}
				   {\xff\x27\x19\x7e\x8c\xf0\x8e\x8f\x20\x98\xec\x92\xeb\x5c\x98\x8f\xde\x63\x61\x3c\xa3\x2d\x72\xb0\xdf\xb7\x32\x33\x60\xe4\xf1\x94\x2c\x31\xdf\x3e\x25\x25\x25\x3f\x81\x81\x82\x82\x80\x81\x90\x99\x45\x45\x45\x45\x49\x49\x49\x49\x44\xee\x4f\x4f\x4f\x4f\x86\x78\x30\x55\x55\x55\x8a\x59\x70\xe2\x84\x83\x84\x84\xe1\x84\x91\x99\x65\x65\x65\x65\x69\x69\x69\x69\x95\xee\x6f\x6f\x6f\x6f\xef\xfd\x88\x75\x75\x75\xf5\x79\xf0\x79};	
	} elsif ($lang eq 'latin1') {
		# golly, the latin1 character map _is_ latin1.  Also, translate funky windows apostrophes to legal ones.
		$line =~ tr{\x92}
				   {\x26};
	};
	
	# start calculating the control strings
	
	my $vfddata = '';
	my $vfdmodel = $client->vfdmodel();

	# force the display out of 4 bit mode if it got there somehow, then set the brightness
	if ( $vfdmodel =~ 'futaba') {
		$vfddata .= $vfdCodeCmd .  $vfdBrightFutaba[$brightness];
	} else {
		$vfddata .= $noritakeBrightPrelude . $vfdBright[$brightness];
	}
	# define required custom characters
	while((my $custc,my $ncustom) = each %customUsed) {
			my $bitmapref = $vfdcustomchars{$ncustom};
			my $bitmap = pack ('C8', @$bitmapref);
			$bitmap =~ s/(.)/$vfdCodeChar$1/gos;
			$vfddata .= $vfdCodeCmd . pack('C',0b01000000 + (ord($custc) * 8)) . $bitmap;
	}	
	
	# put us in incrementing mode and move the cursor home
	$vfddata .= $vfdReset;
	$vfddata .= $vfdCodeCmd . $vfdCommand{"CFF"};
	# include our actual character data
	$line =~ s/(.)/$vfdCodeChar$1/gos;
	
	# split the line in two and move the cursor to the second line
	$line = substr($line, 0, 80) . $vfdCodeCmd . $vfdCommand{"HOME2"} . substr($line, 80);

	$vfddata .= $line;
	
	# set the cursor
	if ($cur >= 0) {
		if ($cur < 40) {
			$vfddata .= $vfdCodeCmd.(pack 'C', (0b10000000 + $cur));
		} else {
			$vfddata .= $vfdCodeCmd.(pack 'C', (0b11000000 + $cur - 40));
		}
		# turn on  the cursor			
		$vfddata .= $vfdCodeCmd. $vfdCommand{'CUR'};
	}

	$client->vfd($vfddata);
	
	my $len = length($vfddata);
	die "Odd vfddata: $vfddata" if ($len % 2);
	die "VFDData too long: $len bytes: $vfddata" if ($len > 500);
}

# the following are the custom character definitions for the new progress/level bar...

Slim::Hardware::VFD::setCustomChar('notesymbol',
				 ( 0b00000100, 
				   0b00000110, 
				   0b00000101, 
				   0b00000101, 
				   0b00001101, 
				   0b00011100, 
				   0b00011000, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('leftprogress0',
				 ( 0b00000111, 
				   0b00001000, 
				   0b00010000, 
				   0b00010000, 
				   0b00010000, 
				   0b00001000, 
				   0b00000111, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('leftprogress1',
				 ( 0b00000111, 
				   0b00001000, 
				   0b00011000, 
				   0b00011000, 
				   0b00011000, 
				   0b00001000, 
				   0b00000111, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('leftprogress2',
				 ( 0b00000111, 
				   0b00001100, 
				   0b00011100, 
				   0b00011100, 
				   0b00011100, 
				   0b00001100, 
				   0b00000111, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('leftprogress3',
				 ( 0b00000111, 
				   0b00001110, 
				   0b00011110, 
				   0b00011110, 
				   0b00011110, 
				   0b00001110, 
				   0b00000111, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('leftprogress4',
				 ( 0b00000111, 
				   0b00001111, 
				   0b00011111, 
				   0b00011111, 
				   0b00011111, 
				   0b00001111, 
				   0b00000111, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('middleprogress0',
				 ( 0b01111111, 
				   0b00000000, 
				   0b00000000, 
				   0b00000000, 
				   0b00000000, 
				   0b00000000, 
				   0b01111111, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('middleprogress1',
				 ( 0b01111111, 
				   0b01110000, 
				   0b01110000, 
				   0b01110000, 
				   0b01110000, 
				   0b01110000, 
				   0b01111111, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('middleprogress2',
				 ( 0b01111111, 
				   0b01111000, 
				   0b01111000, 
				   0b01111000, 
				   0b01111000, 
				   0b01111000, 
				   0b01111111, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('middleprogress3',
				 ( 0b01111111, 
				   0b01111100, 
				   0b01111100, 
				   0b01111100, 
				   0b01111100, 
				   0b01111100, 
				   0b01111111, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('middleprogress4',
				 ( 0b01111111, 
				   0b01111110, 
				   0b01111110, 
				   0b01111110, 
				   0b01111110, 
				   0b01111110, 
				   0b01111111, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('rightprogress0',
				 ( 0b01111100, 
				   0b00000010, 
				   0b00000001, 
				   0b00000001, 
				   0b00000001, 
				   0b00000010, 
				   0b01111100, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('rightprogress1',
				 ( 0b01111100, 
				   0b01110010, 
				   0b01110001, 
				   0b01110001, 
				   0b01110001, 
				   0b01110010, 
				   0b01111100, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('rightprogress2',
				 ( 0b01111100, 
				   0b01111010, 
				   0b01111001, 
				   0b01111001, 
				   0b01111001, 
				   0b01111010, 
				   0b01111100, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('rightprogress3',
				 ( 0b01111100, 
				   0b01111110, 
				   0b01111101, 
				   0b01111101, 
				   0b01111101, 
				   0b01111110, 
				   0b01111100, 
				   0b00000000 ));

Slim::Hardware::VFD::setCustomChar('rightprogress4',
				 ( 0b01111100, 
				   0b01111110, 
				   0b01111111, 
				   0b01111111, 
				   0b01111111, 
				   0b01111110, 
				   0b01111100, 
				   0b00000000 ));
				   
Slim::Hardware::VFD::setCustomChar('mixable', (
					0b00011111,
					0b00000000,
					0b00011010,
					0b00010101,
					0b00010101,
					0b00000000,
					0b00011111,
					0b00000000   ));

Slim::Hardware::VFD::setCustomChar('bell', (
					0b00000100,
					0b00001010,
					0b00001010,
					0b00011011,
					0b00010001,
					0b00011111,
					0b00000100,
					0b00000000   ));
					
# replaces ~ in format string
# setup the special characters
Slim::Hardware::VFD::setCustomChar( 'toplinechar',	
					(	0b01111111, 
						0b00000000, 
						0b00000000, 
						0b00000000, 
						0b00000000, 
						0b00000000, 
						0b00000000, 
						0b00000000	 ));

# replaces = in format string
Slim::Hardware::VFD::setCustomChar( 'doublelinechar', 
					(	0b00011111, 
						0b00000000, 
						0b00000000, 
						0b00000000, 
						0b00000000, 
						0b00000000, 
						0b00000000, 
						0b00011111	 ));

# replaces ? in format string.  Used in Z, ?, 7
Slim::Hardware::VFD::setCustomChar( 'Ztop', 		
			(      		0b01111111,
						0b00000001,
						0b00000001,
						0b00000010,
						0b00000100,
						0b00001000,
						0b00010000,
						0b00100000   ));
                  
# replaces < in format string.  Used in Z, 2, 6
Slim::Hardware::VFD::setCustomChar( 'Zbottom', 		
			(   		0b00000001,
						0b00000010,
						0b00000100,
						0b00001000,
						0b00010000,
						0b00010000,
						0b00011111,
						0b00000000   ));
                  
# replaces / in format string.
Slim::Hardware::VFD::setCustomChar( 'slash', 	
				(     	0b00000011,
						0b00000100,
						0b00001000,
						0b00001000,
						0b00010000,
						0b00010000,
						0b00010000,
						0b00000000   ));
                  
Slim::Hardware::VFD::setCustomChar( 'backslash', 	
				( 		0b00011000,
						0b00000100,
						0b00000010,
						0b00000010,
						0b00000001,
						0b00000001,
						0b00000001,
						0b00000000   ));

Slim::Hardware::VFD::setCustomChar( 'islash', 	
				(     	0b00010000,
						0b00010000,
						0b00010000,
						0b00001000,
						0b00001000,
						0b00000100,
						0b00000011,
						0b00000000   ));
                   
Slim::Hardware::VFD::setCustomChar( 'ibackslash', 	
				( 		0b00000001,
						0b00000001,
						0b00000001,
						0b00000010,
						0b00000010,
						0b00000100,
						0b00011000,
						0b00000000   ));

Slim::Hardware::VFD::setCustomChar( 'filledcircle',		
					 ( 	0b00000001,
						0b00001111,
						0b00011111,
						0b00011111,
						0b00011111,
						0b00001110,
						0b00000000,
						0b00000000   ));	

Slim::Hardware::VFD::setCustomChar( 'leftvbar',		
					 ( 	0b00010000,
						0b00010000,
						0b00010000,
						0b00010000,
						0b00010000,
						0b00010000,
						0b00010000,
						0b00000000   ));	

Slim::Hardware::VFD::setCustomChar( 'rightvbar',		
					 ( 	0b00000001,
						0b00000001,
						0b00000001,
						0b00000001,
						0b00000001,
						0b00000001,
						0b00000001,
						0b00000000   ));	

Slim::Hardware::VFD::setCustomChar('leftmark',
 					(   0b00011111,
						0b00000001,
						0b00000001,
						0b00000001,
						0b00000001,
						0b00000001,
						0b00011111,
						0b00000000   ));
                  
Slim::Hardware::VFD::setCustomChar('rightmark',
					( 	0b00011111,
						0b00010000,
						0b00010000,
						0b00010000,
						0b00010000,
						0b00010000,
						0b00011111,
						0b00000000   ));
                  

my $leftvbar = Slim::Display::Display::symbol('leftvbar');
my $rightvbar = Slim::Display::Display::symbol('rightvbar');
my $slash = Slim::Display::Display::symbol('slash');
my $backslash = Slim::Display::Display::symbol('backslash');
my $islash = Slim::Hardware::VFD::symbol('islash');
my $ibackslash = Slim::Hardware::VFD::symbol('ibackslash');
my $toplinechar = Slim::Display::Display::symbol('toplinechar');
my $doublelinechar = Slim::Display::Display::symbol('doublelinechar');
my $Zbottom = Slim::Display::Display::symbol('Zbottom');
my $Ztop = Slim::Display::Display::symbol('Ztop');
my $notesymbol = Slim::Display::Display::symbol('notesymbol');
my $filledcircle = Slim::Display::Display::symbol('filledcircle');
my $rightarrow = Slim::Display::Display::symbol('rightarrow');
my $cursorpos = Slim::Display::Display::symbol('cursorpos');
my $hardspace = Slim::Display::Display::symbol('hardspace');
my $centerchar = Slim::Display::Display::symbol('center');

# double sized characters
my %doublechars = (
	
	"(" => [ $slash,
			 $islash ],
	
	")" => [ $backslash,
			 $ibackslash ],
	
	"[" => [ $rightvbar . $toplinechar,
			 $rightvbar . '_' ],
	
	"]" => [ $toplinechar . $leftvbar,
			 '_' . $leftvbar],
	
	"<" => [ '/',
			 '\\' ],
	
	">" => [ '\\',
			 '/' ],
	
	"{" => [ '(',
			 '(' ],
	
	"}" => [ ')',
			 ')' ],
	
	'"' => [ '\'\'',
			 $hardspace . $hardspace],
	"%" => [ 'o/', '/o'],
	"&" => [ '_' . 'L', $backslash . $leftvbar],
	"^" => [ $slash . $backslash, $hardspace . $hardspace],
	" " => [ $hardspace . $hardspace, $hardspace . $hardspace ],
	"'" => [ '|', $hardspace ],
	"!" => [ '|', '.' ],
	":" => [ '.', '.' ],
	"." => [ $hardspace, '.' ],
	";" => [ '.', ',' ],
	"," => [ $hardspace, '/' ],
	"`" => [ $backslash, $hardspace ],
	
	"_" => [ $hardspace . $hardspace, '_' . '_' ],
	
	"+" => [ '_' . 'L', $hardspace . $leftvbar],
	
	"*" => [ '**', '**'],
	
	'~' => [ $slash . $toplinechar, $hardspace . $hardspace ],
	
	"@" => [ $slash . 'd',
			 $backslash . '_' ],
	
	"#" => [ '_' . $Zbottom . $Zbottom, $Ztop . $Ztop . $toplinechar ],
	
	'$' => [ '$$', '$$' ],
	
	"|" => [ '|',
			 '|' ],
	
	"-" => [ '_' . '_',
			 $hardspace . $hardspace ],
	
	"/" => [ $hardspace . $slash,
			 $slash . $hardspace ],
	
	"\\" => [ $backslash . $hardspace,
			  $hardspace . $backslash ],
	
	"=" => ['--'
		   ,'--'],
	
	'?' => [$toplinechar . $Ztop,
		,' .'],

	$cursorpos => ['',''],
		
	$notesymbol => [ $leftvbar . $backslash , $filledcircle . " "],

	$rightarrow => [ ' _' . $backslash , $hardspace . $toplinechar . '/'],

	$hardspace => [ $hardspace, $hardspace],
	
	$centerchar => [$centerchar,$centerchar]
	,'0' => [$slash . $backslash, $islash . $ibackslash]
	,'1' => [$hardspace . '\'' . $leftvbar , $hardspace . '_' . 'L']
	,'2' => [$hardspace . $toplinechar . ')' , $hardspace . $slash . '_']
	,'3' => [$hardspace . $doublelinechar . ')' , ' _)']
	,'4' => [$rightvbar . '_' . $leftvbar , $hardspace . $hardspace . $leftvbar]
	,'5' => [$rightvbar . $doublelinechar . $toplinechar , ' _)']
	,'6' => [$hardspace . '/' . $hardspace , '(' . $doublelinechar . ')']
    ,'7' => [$toplinechar . $toplinechar . '/' , $hardspace . $slash . $hardspace]
	,'8' => ['(' . $doublelinechar . ')' , '(_)']
	,'9' => ['(' . $doublelinechar . ')' , $hardspace . $slash . $hardspace]
	,'A' => [$hardspace . $slash . $backslash . $hardspace , $rightvbar . $toplinechar . $toplinechar . $leftvbar]
	,'B' => [$rightvbar . $doublelinechar . ')' , $rightvbar . '_)']
	,'C' => [$slash . $toplinechar , $islash . '_']
	,'D' => [$rightvbar . $toplinechar . $backslash , $rightvbar . '_' . $ibackslash]
	,'E' => [$rightvbar . $doublelinechar , $rightvbar . '_']
	,'F' => [$rightvbar . $doublelinechar , $rightvbar . $hardspace]
	,'G' => [$slash . $doublelinechar . $hardspace , $islash . '_' . $leftvbar]
	,'H' => [$rightvbar . '_' . $leftvbar , $rightvbar . $hardspace . $leftvbar]
	,'I' => [$hardspace . $leftvbar , $hardspace . $leftvbar]
	,'J' => [$hardspace . $rightvbar, $islash . $ibackslash]
	,'K' => [$rightvbar . $ibackslash , $rightvbar . $backslash]
	,'L' => [$rightvbar . $hardspace , $rightvbar . '_']
	,'M' => [$rightvbar . $islash . $ibackslash . $leftvbar , $rightvbar . $hardspace . $hardspace . $leftvbar]
	,'N' => [$rightvbar . '\\' . $leftvbar , $rightvbar . $hardspace . $leftvbar]
	,'O' => [$slash . $backslash , $islash . $ibackslash]
	,'P' => [$rightvbar . $doublelinechar .')' , $rightvbar . $hardspace . $hardspace]
	,'Q' => [$slash . $backslash , $islash . 'X']
	,'R' => [$rightvbar . $doublelinechar . ')' , $rightvbar . $hardspace . $backslash]
	,'S' => ['(' . $toplinechar , '_)']
	,'T' => [$toplinechar . 'T' . $toplinechar , ' | ']
	,'U' => [$leftvbar . $rightvbar , $islash . $ibackslash]
	,'V' => [$leftvbar . $rightvbar , $backslash . $slash]
	,'W' => [$leftvbar . $hardspace . $hardspace . $rightvbar , $islash . $ibackslash . $islash . $ibackslash]
	,'X' => [$islash . $ibackslash , $slash . $backslash]
	,'Y' => [$islash . $ibackslash, $rightvbar . $leftvbar]
	,'Z' => [$toplinechar . '/' , '/' . '_']
	,'Æ' => [$hardspace . $slash . $backslash . $doublelinechar , 
             $rightvbar . $toplinechar . $toplinechar . 'L']
	,'Ø' => [$slash . $toplinechar . 'X', $backslash . $Zbottom . $slash]
	,'Ð' => [$rightvbar . $doublelinechar . $backslash , $rightvbar . '_'  . $slash]
);

sub addDoubleChar {
	my ($char,$doublechar) = @_;
	if (!exists $doublechars{$char} && ref($doublechar) eq 'ARRAY' 
			&& Slim::Display::Display::lineLength($doublechar->[0]) == Slim::Display::Display::lineLength($doublechar->[1])) {
		$doublechars{$char} = $doublechar;
	} else {
		if ($::d_display) {
			msg("Could not add character $char, it already exists.\n") if exists $doublechars{$char};
			msg("Could not add character $char, doublechar is not array reference.\n") if ref($doublechar) ne 'ARRAY';
			msg("Could not add character $char, lines of doublechar have unequal lengths.\n")
				if Slim::Display::Display::lineLength($doublechar->[0]) != Slim::Display::Display::lineLength($doublechar->[1]);
		}
	}
}

sub updateDoubleChar {
	my ($char,$doublechar) = @_;
	if (ref($doublechar) eq 'ARRAY' 
			&& Slim::Display::Display::lineLength($doublechar->[0]) == Slim::Display::Display::lineLength($doublechar->[1])) {
		$doublechars{$char} = $doublechar;
	} else {
		if ($::d_display) {
			msg("Could not update character $char, doublechar is not array reference.\n") if ref($doublechar) ne 'ARRAY';
			msg("Could not update character $char, lines of doublechar have unequal lengths.\n")
				if Slim::Display::Display::lineLength($doublechar->[0]) != Slim::Display::Display::lineLength($doublechar->[1]);
		}
	}
}

# the font format string
#my $double = 
	# all digits are 3 chars wide
#	'0/~\01 /[12 ~)23 =)34]_[45]=~56 < 67 ~?78(=)89(=)9' .
#	'0\_/01  [12 <_23 _)34  [45 _)56(_)67 / 78(_)89 / 9' .
#	# kerning is custom so exclude blanks here except for 'I'
#	'A /\ AB]=)BC/~CD]~\DE]=EF]=FG/~ GH]_[HI [IJ  [J' .
#	'A]~~[AB]_)BC\_CD]_/DE]_EF] FG\=[GH] [HI [IJ]_[J' .
#	'K]/KL] LM]\/[MN]\[NO/~\OP]=)PQ/~\QR]=)RS(~S' .
#	'K]\KL]_LM]  [MN] [NO\_/OP]  PQ\_xQR] \RS_)S' .
#	'T~|~TU] [UV[]VW[  ]WX\/XY\/YZ~?Z' .
#	'T | TU]_[UV\/VW\/\/WX/\XY [YZ<_Z';
	
#my $kernL = '\~\]\?\_\<\=';
#my $kernR = '\~\[\<\_\\\\/';

my $kernL = qr/(?:$toplinechar|$rightvbar|$Ztop|_|$Zbottom|$doublelinechar)$/o;
my $kernR = qr/^(?:$toplinechar|$leftvbar|$Zbottom|_|$backslash|$slash)/o;

#
# double the height and width of a string to display in doubled mode
#
sub doubleSize {
	my $client = shift;
	my $undoubled = shift;

	my ($newline1, $newline2) = ("", "");
	my $line2 = $undoubled;
	
	$line2 =~ s/$cursorpos//g;
	$line2 =~ s/^(\s*)(.*)/$2/;
	
	$::d_ui && msg("doubling: $line2\n");

	$line2 =~ tr/\x{00E6}\x{00F8}\x{00F0}/\x{00C6}\x{00D8}\x{00D0}/;
	$line2 =~ tr/\x{00C5}\x{00E5}/AA/;
	
	my $lastch1 = "";
	my $lastch2 = "";
   
	my $lastchar = "";
	
	my $split = Slim::Display::Display::splitString($line2);
	
	foreach my $char (@$split) {
		if (exists($doublechars{$char}) || exists($doublechars{Slim::Utils::Text::matchCase($char)})) {
			my ($char1,$char2);
			if (!exists($doublechars{$char})) {
				$char = Slim::Utils::Text::matchCase($char);
			}
			($char1,$char2)=  @{$doublechars{$char}};
			if ($char =~ /[A-Z]/ && $lastchar ne ' ' && $lastchar !~ /\d/) {
					if (($lastch1 =~ $kernL && $char1 =~ $kernR) ||
						 ($lastch2 =~ $kernL && $char2 =~ $kernR)) {
					
						if ($lastchar =~ /[CGLSTZ]/ && $char =~ /[COQ]/) {
							# Special cases to exclude kerning between
						} else {
						   $newline1 .= ' ';
						   $newline2 .= ' ';
						}
					}
			}
			$lastch1 = $char1;
			$lastch2 = $char2;
			$newline1 .= $char1;
			$newline2 .= $char2;
		} else {
			$::d_display && msg("Character $char has no double\n");
			next;
		}
		$lastchar = $char;
	}
	
	return ($newline1, $newline2);
}

1;

__END__

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
