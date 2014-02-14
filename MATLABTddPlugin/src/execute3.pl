#!/usr/bin/perl -w

# ===========================================================================#
#   Script per le sottomissioni MATLAB
#
#   usage:
#       execute3.pl <properties-file>
##============================================================================

use Config::Properties::Simple;
use IPC::System::Simple qw[ capture system ];
use File::Basename qw[ basename dirname fileparse ];
use File::Copy "cp";
use File::Spec::Functions "catfile";
use File::Path qw[ make_path remove_tree ];
use Web_CAT::Beautifier;
use Web_CAT::CLOC;
use Web_CAT::FeedbackGenerator;

use feature "switch";
use strict;
use warnings;

die "You need to upgrade your perl interpreter (" . $^V . " < v5.10.0)."
  if $^V lt 'v5.10.0';

#==========================================================================##
# Fase 0.1: salvo le proprieta` passate allo script in variabili
##==========================================================================#
my $propfile = $ARGV[0];    # property file name
my $cfg = Config::Properties::Simple->new( file => $propfile );

# few useful directories
# ---------
my $matlabDir     = $cfg->getProperty('matlabBinariesPath');
my $logDir        = $cfg->getProperty('resultDir');
my $resultDir     = $logDir;
my $submissionDir = dirname($logDir);
my $workingDir    = $cfg->getProperty('workingDir');
my $pluginHome    = $cfg->getProperty('pluginHome');
my $pluginData    = $cfg->getProperty( 'pluginData', '.' );

# TODO: debug property
# ---------
my $debug = 1;    # $cfg->getProperty('debug');

# TODO: properties da sistemare
my $timeout        = $cfg->getProperty( 'timeout',        10 );
my $reportCount    = $cfg->getProperty( 'numReports',     0 );
my $numCodeMarkups = $cfg->getProperty( 'numCodeMarkups', 0 );

my $maxCorrectnessScore = $cfg->getProperty('max.score.correctness');
my $maxToolScore = $cfg->getProperty( 'max.score.tools', 0 );

print "logDir = resultDir = $logDir\n"
  . "submissionDir = $submissionDir\n"
  . "workingDir = $workingDir\n"
  . "pluginData = $pluginData\n"
  . "pluginHome = $pluginHome\n"
  if $debug;

#==========================================================================##
# Fase 0.2: inizializzo tutte le variabili che possono servire
##==========================================================================#

# log variables
# ---------
my $explanationRelative = "explanation.log";
my $explanation         = catfile( $logDir, $explanationRelative );
my $failLogRelative     = "fail.log";
my $failLog             = catfile( $logDir, $failLogRelative );
my $instrLogRelative    = "instr.log";
my $instrLog            = catfile( $logDir, $instrLogRelative );
my $rawLogRelative      = "raw.log";
my $rawLog              = catfile( $logDir, $rawLogRelative );
my $timeoutLogRelative  = "timeout.log";
my $timeoutLog          = catfile( $logDir, $timeoutLogRelative );

# matlab variables
# ---------
my $matlabExecutable = "matlab";
my $mStub            = catfile( $workingDir, "stub.m" );
my $matlabExecute    = catfile( $matlabDir, $matlabExecutable );
my @matlabArgs       = qw( -nodesktop -nosplash -nodisplay -nojvm );

#==========================================================================##
# Fase 0.3: routines che possono far comodo
##==========================================================================#

# calcola il path assoluto di subpath (a partire da $pluginData)
sub findScriptPath {
	my $subpath = shift;
	my $dest = catfile( $pluginData, $subpath );

	return $dest if -e $dest;
	die "It seems that $subpath does not exist in $pluginData directory.";
}

sub isAnArchive {
	my $sourceArchive = shift;
	return "" if ( not -e $sourceArchive ) or -d $sourceArchive;

	my @allowedExts = qw( .zip .tar.gz .tar.bz2 );
	foreach my $ext (@allowedExts) {
		return $ext if $sourceArchive =~ /\Q$ext\E$/;
	}
	return "";
}

# &genericCopier($property from an opened Properties object)
sub genericCopier {
	my $property = shift;
	print "property = $property\n" if $debug;

	my $relativeFile = $cfg->getProperty( $property, "" );
	print "$property realtiveFile = $relativeFile\n" if $debug;

	return "" if ( not defined $relativeFile ) or $relativeFile eq "";

	my $source = findScriptPath($relativeFile);
	print "source = $source\n" if $debug;
	die " Sorry, only one m-file allowed for local files inclusion."
	  if ( not -e $source )
	  or -d $source;

	my $relativeFileName = basename($source);
	my $dest = catfile( $workingDir, $relativeFileName );
	print "relativeFileName = $relativeFileName\n" . "dest = $dest\n" if $debug;

	my $ec = cp( $source, $dest );
	print "cp $source -> $dest\n" if $debug;
	return ( $ec == 1 ) ? $dest : "";
}

sub unpackFile {
	my $sourceArchive = shift;
	my $destDir       = shift;

	my $archiveName = basename($sourceArchive);
	die "It seems that $archiveName is not a valid archive"
	  if ( not -e $sourceArchive )
	  or -d $sourceArchive;

	my $found = &isAnArchive($sourceArchive);
	die "It seems that $archiveName is not a valid archive" if $found eq "";

	my $listCommand   = "";
	my $unpackCommand = "";
	given ($found) {
		when (".zip") {
			$listCommand =
			  "unzip -l \"$sourceArchive\" | awk '{print \$NF}' | grep \.m\$";
			$unpackCommand = "unzip \"$sourceArchive\" -d \"$destDir\"";
		}
		when (".tar.gz") {
			$listCommand =
			  "tar tzf \"$sourceArchive\" | awk '{print \$NF}' | grep \.m\$";
			$unpackCommand = "tar xzf \"$sourceArchive\" -C \"$destDir\"";
		}
		when (".tar.bz2") {
			$listCommand =
			  "tar tjf $sourceArchive | awk '{print \$NF}' | grep \.m\$";
			$unpackCommand = "tar xjf \"$sourceArchive\" -C \"$destDir\"";
		}
		default {

			# a regola, questo codice non verra` MAI eseguito
			die "It seems that $archiveName is not a valid archive"
			  if $found eq "";
		}
	}

	# conterra` i paths relativi di tutti gli m-files studente
	my @studentFilenames = ();

	my @archList = capture($listCommand);

	foreach my $l (@archList) {
		push @studentFilenames, basename($l);

		print "chroot $destDir $unpackCommand\n" if $debug;

		# chroot [OPTION] NEWROOT [COMMAND [ARG]...]
		system("chroot $destDir $unpackCommand \"$l\"");
	}

	return @studentFilenames;
}

# made to extract class test name, and the number of test methods
# it needs an absolute path of a test class file
sub testCasesProperties {
	my $testCasesClass = shift;
	print "test Cases Class = $testCasesClass\n" if $debug;

	my $testCasesClassName = "";
	my $testMethodsCount   = 0;

	open CLASS, "$testCasesClass"
	  or die "Troubles opening " . basename($testCasesClass);

	my $canStartToCount = 0;

	while ( my $line = <CLASS> ) {
		given ($line) {
			next when /^%/;

			when (/^.*\s*classdef\s+([\w\d]+)\s*<\s*matlab\.unittest/) {
				$testCasesClassName = $1;
				print "tests class name: $testCasesClassName\n" if $debug;

			}

			when (/^\s*function\s+[\w\d]+\(\s*[\w\d]+\s*\)/) {
				$testMethodsCount++ if $canStartToCount;
			}

			$canStartToCount = 1 when (/^\s*methods\s+\(\s*Test\s*\)/);

			$canStartToCount = 0 when (/^\s*methods\s+\(\s*^(Test)\s*\)/);
		}
	}
	close CLASS;
	return ( $testCasesClassName, $testMethodsCount );
}

#==========================================================================##
# Fase 1: setup della workingDir
# (e.g. ~/Programs/apache-tomcat-7.0.50/temp/unipi/student)
##==========================================================================#

# copia files studenti nella workingDir
# ---------

# ottengo la lista dei files (archivi o m-files) presenti nella cartella di
# sottomissione dello studente
opendir DIR, $submissionDir or die $!;
my @fileNames = ();
while ( my $file = readdir(DIR) ) {
	my $fileName = catfile( $submissionDir, $file );
	print "$fileName\n" if $debug;
	push @fileNames, $fileName
	  if -f $fileName
		  and ( $fileName =~ /\.m$/ or &isAnArchive($fileName) ne "" );
}
closedir DIR;

# a regola @fileNames dovrebbe contenere un solo elemento!
my $filePath = shift @fileNames;
@fileNames = ();
if ( $filePath =~ /\.m$/ ) {
	my $fileName = basename($filePath);
	push @fileNames, $fileName;
	make_path( $workingDir, { verbose => ( $debug ? 1 : 0 ) } )
	  if not -d $workingDir;
	my $dest = catfile( $workingDir, $fileName );
	print "cp $filePath -> $dest\n" if $debug;
	cp( $filePath, $dest );

}
else {
	@fileNames = &unpackFile( $filePath, $workingDir );
}

# copia file di dataset nella workingDir
# ---------
my ( $localFilePath, $localFileName, $localFile ) = ( "", "", "" );
$localFile = &genericCopier('localFiles');
( $localFilePath, $localFileName ) = fileparse($localFile) if $localFile ne "";

# copia altri eventuali m-files docente nella workingDir
# ---------
my ( $otherFilePath, $otherFileName, $otherFile ) = ( "", "", "" );
$otherFile = &genericCopier('generalIncludes');
( $otherFilePath, $otherFileName ) = fileparse($otherFile) if $otherFile ne "";

# copia casi di test docente nella workingDir
# ---------
my ( $testCasePath, $testCaseName, $testCaseFile ) = ( "", "", "" );
$testCaseFile = &genericCopier('testCases');

if ( $testCaseFile eq "" ) {
	my $defaultCasesFile = "instrTest.m";
	my $source           = catfile( $pluginHome, "tests", $defaultCasesFile );
	my $dest             = catfile( $workingDir, $defaultCasesFile );

	cp( $source, $dest );
	print "cp $source -> $dest\n" if $debug;
	$testCaseFile = $dest if -f $dest;
}

# estrae classname e numero di metodi di test
# ---------
my ( $testCasesClassName, $testMethodsCount ) = ( "", 0 );
( $testCasesClassName, $testMethodsCount ) =
  &testCasesProperties($testCaseFile);

$testCasesClassName = "DefaultTest" if $testCasesClassName eq "";

print "TestMethods: $testMethodsCount\n", "TestClassName: $testCasesClassName\n"
  if $debug;

# creazione di un nuovo m-file nella workingDir che all'avvio ripristina
# il search path di matlab e vi appende la workingDir
# ---------
open MSTUB, ">$mStub" or die 'Troubles opening the m-file stub';
print MSTUB "restoredefaultpath\n"
  . "savepath\n"
  . "addpath(genpath('$workingDir'))\n";    # prologo

foreach my $mfile (@fileNames) {            # checkcode
	print MSTUB "disp(sprintf('\\n\\n===== checkcode "
	  . "$mfile start ====='))\n"
	  . "checkcode('$mfile')\n"
	  . "disp(sprintf('\\n\\n===== checkcode end ====='))\n";
}

print MSTUB "testCase = $testCasesClassName;\n"
  . "results = run(testCase);\n"
  . "N = size(results, 2);\n"
  . "for j=1:N,\n"
  . "Name = results(j).Name;\n"
  . "Passed = results(j).Passed;\n"
  . "Failed = results(j).Failed;\n"
  . "Incomplete = results(j).Incomplete;\n"
  . "Duration = results(j).Duration;\n"
  . "disp(sprintf('\\n\\nName: %s, Passed: %d, Failed: %d, Incomplete: %d, "
  . "Duration: %.4f.', Name, Passed, Failed, Incomplete, Duration))\n"
  . "end\n";    # formattazione dell'output

# TODO: profiler

print MSTUB
  "clearvars testCase results N j Name Passed Failed Incomplete Duration\n"
  . "quit\n";    # epilogo
close MSTUB;

#==========================================================================##
# Fase 2: esecuzione script matlab e cattura output
##==========================================================================#

make_path( $logDir, { verbose => ( $debug ? 1 : 0 ) } ) if not -d $logDir;

print "\\$matlabExecute " . join( " ", @matlabArgs ) . " < \"$mStub\"\n"
  if $debug;

my @stdout =
  capture( "\\$matlabExecute " . join( " ", @matlabArgs ) . " < \"$mStub\"" );

chomp(@stdout);
print "\@stodut troubles\n" if not @stdout;

#==========================================================================##
# Fase 3: analisi ed organizzazione dell'output generato da matlab
##==========================================================================#

# strutture utili
# ---------

# %codeMarkupIds is a map from file names to codeMarkup numbers
my %codeMarkupIds = ();

# hashes of hashes per i reports generati dalla routine checkcode
my %codeMessages = ();

# array per la collezione dei reports provenienti dai tests
my @testsReports = ();

# array per la collezioni dei dettagli sui tests falliti
my @failedDetails = ();

# contatori
# ---------
my ( $testFailedCount, $testIncompleteCount, $testPassedCount ) = ( 0, 0, 0 );
my ( $testFailedTime,  $testIncompleteTime,  $testPassedTime )  = ( 0, 0, 0 );

# analisi dell'output
# ---------
for my $i ( 0 .. $#stdout ) {
	$stdout[$i] =~ s/(>>\s+)+//g;

	given ( $stdout[$i] ) {

		# cerco di riconoscere l'esecuzione di uno o piu` tests
		when (
			/^Name:\s+([\w\d\/]+),
		\s+Passed:\s+(\d+),
		\s+Failed:\s+(\d+),
		\s+Incomplete:\s+(\d+),
		\s+Duration:\s+(\d+\.\d+)\./x
		  )
		{
			my $tmpFloat = $5 + 0;
			my %tmpHash  = (
				name       => $1,
				passed     => $2,
				failed     => $3,
				incomplete => $4,
				duration   => $tmpFloat
			);

			if ( $tmpHash{passed} =~ /^(true|on|yes|y|1)$/i ) {
				$testPassedCount++;
				$testPassedTime += $tmpFloat;
			}
			elsif ( $tmpHash{incomplete} =~ /^(true|on|yes|y|1)$/i ) {
				$testIncompleteCount++;
				$testIncompleteTime += $tmpFloat;
			}
			else {
				$testFailedCount++;
				$testFailedTime += $tmpFloat;
			}

			push @testsReports, \%tmpHash;
		}

		# cerco di riconoscere l'output fornito da checkcode
		when (/^={5}\s+checkcode\s+([\w\d]+\.m)\s+start\s+={5}$/) {
			my $tmpFile = $1;
			my @items   = ();
			print "checkcode file: $tmpFile\n" if $debug;

			# individuazione dei messaggi di checkcode
			for ( $i++ ; not $stdout[$i] =~ /^={5} checkcode end ={5}$/ ; $i++ )
			{
				chomp $stdout[$i];
				$stdout[$i] =~ s/(>>\s+)+//g;
				print "checkcode: ", $stdout[$i], "\n" if $debug;
				push @items, $stdout[$i];
			}

			# analisi
			# ---------
			my $last;

			foreach my $item (@items) {
				$item =~ s/^\s+//;
				chomp($item);

				if ( $item =~ /^L\s+(\d+)\s+\(C\s+\d+(?:-\d+)?\):\s*(.+)/ ) {
					my $no = int $1;
					$last = $no;
					my $text = $2;

					if ( not defined $codeMessages{$tmpFile} ) {
						$codeMessages{$tmpFile}->{$no} = {
							category   => 'Suggestion',
							coverage   => '',
							message    => "$text"
						};
						next;
					}

					my $found = 0;
					for my $key ( sort %{ $codeMessages{$tmpFile} } ) {
						if ( $key == $no ) {
							$codeMessages{$tmpFile}->{$no}->{message} .=
							  "\n$text";

							my $violation_ref =
							  $codeMessages{$tmpFile}->{$no}->{violations}->[0];
							$violation_ref->{message} .= "\n$text";
							$found = 1;
							last;
						}
					}

					if ( not $found ) {
						$codeMessages{$tmpFile}->{$no} = {
							category   => 'Suggestion',
							coverage   => '',
							message    => "$text"
						};
					}

					next;
				}

				if ($last) {
					$codeMessages{$tmpFile}->{$last}->{message} .= " $item";
				}
			}

			# %codeMessages is a hash like this:
			# {
			#   filename1 => {
			#                  <line num> => {
			#                                   category => coverage,
			#                                   coverage => "...",
			#                                   message  => "...",
			#									violations => [ ... ]
			#                                },
			#                  <line num> => { ...
			#                                },
			#                },
			#   filename2 => { ...
			#                },
			# }

			if ($debug) {
				for my $key ( keys %codeMessages ) {
					print "$key => ";
					foreach my $no ( sort keys %{ $codeMessages{$key} } ) {
						print "$no {\n";
						print "\t"
						  . $codeMessages{$key}->{$no}->{category} . "\n";
						print "\t"
						  . $codeMessages{$key}->{$no}->{message} . "\n";
					}
				}
			}
		}

		# collecting test extended reports
		when (/^={80}$/) {
			$i++;
			if ( $stdout[$i] =~ /in\s+([^.!?\-\s]+)\.$/ ) {
				my $tmpMethodName = $1;
				print "${1}\n";
				my $tmpDetails = "";

				for ( $i++ ; not $stdout[$i] =~ /^={80}$/ ; $i++ ) {
					chomp $stdout[$i];
					$stdout[$i] =~ s/(>>\s+)+//g;

					$tmpDetails .= "\n"
					  if ( $stdout[$i] =~ /^\s*Expected Value:\s*$/ );

					$tmpDetails .= $stdout[$i] . "\n";
				}
				if ( $tmpDetails ne "" ) {
					my %tmpHash = (
						method  => $tmpMethodName,
						details => $tmpDetails
					);
					push @failedDetails, \%tmpHash;
				}
			}
			next;
		}
		default {
			next;
		}
	}
	print $stdout[$i] . "\n" if $debug;
}

# ---------
if ($debug) {
	for my $j ( 0 .. $#testsReports ) {
		print "[$j]: "
		  . $testsReports[$j]{name} . " "
		  . $testsReports[$j]{passed} . " "
		  . $testsReports[$j]{failed} . " "
		  . $testsReports[$j]{incomplete} . " "
		  . $testsReports[$j]{duration} . "\n";
	}
}

#==========================================================================##
# Fase 4: creazione output verso docenti e studenti
##==========================================================================#

# il numero totale dei tests ricavato con la routine testCasesProperties
# dev'esser pari al numero di test passati + falliti + incompleti
# qui viene controllato se e` davvero cosi`.
my $computedMethodsCount =
  $testPassedCount + $testFailedCount + $testIncompleteCount;
if ( $computedMethodsCount != $testMethodsCount ) {
	print "Something went wrong counting test results\n" if $debug;
	$testMethodsCount = $computedMethodsCount;
}

# calcolo delle percentuali di tests passati/falliti/incompleti
# ----
my $testPassedPercent =
  sprintf( "%.2f", ( $testPassedCount / $testMethodsCount ) * 100 );
my $testFailedPercent =
  sprintf( "%.2f", ( $testFailedCount / $testMethodsCount ) * 100 );
my $testIncompletePercent =
  sprintf( "%.2f", ( $testIncompleteCount / $testMethodsCount ) * 100 );

my $feedbackGenerator = new Web_CAT::FeedbackGenerator($instrLog);
$feedbackGenerator->startFeedbackSection("Estimate of Problem Coverage");

if ( $testPassedCount == $testMethodsCount ) {
	$feedbackGenerator->print( <<EOF );
<p>You passed in <b>all (100%) the $testMethodsCount tests</b>.</p>
<p>Your solution appears to cover all required behavior for this assignment.</p>
EOF
}
elsif ( $testFailedCount == $testMethodsCount ) {
	$feedbackGenerator->print( <<EOF );
<p>You failed in <b>all the $testMethodsCount tests</b>.</p>
<p>Double check that you have carefully followed all initial conditions
requested in the assignment in setting up your solution, and that you
have also met all requirements for a complete solution in the final
state of your program.
</p>
EOF
}
elsif ( $testIncompleteCount == $testMethodsCount ) {
	$feedbackGenerator->print( <<EOF );
<p>For some reason <b>the system could not complete each of the $testMethodsCount tests</b>.</p>
<p>Double check that you have carefully followed all initial conditions
requested in the assignment in setting up your solution, and that you
have also met all requirements for a complete solution in the final
state of your program.
</p>
EOF
}
else {
	if ( $testPassedCount > 0 ) {
		$feedbackGenerator->print( <<EOF );
<p>You passed <b>$testPassedCount</b> (of $testMethodsCount,
<font color="#ee00bb">$testPassedPercent%</font>).</p>
<p>Your code appears to cover <font color="#ee00bb">only $testPassedPercent%</font>
of the behavior required for this assignment.</p>
EOF
	}

	if ( $testFailedCount > 0 ) {
		$feedbackGenerator->print( <<EOF );
<p>You failed <b>$testFailedCount</b> (of $testMethodsCount,
<font color="#ee00bb">$testFailedPercent%</font>).</p>
<p>Double check that you have carefully followed all initial conditions
requested in the assignment in setting up your solution, and that you
have also met all requirements for a complete solution in the final
state of your program.
</p>
EOF
	}

	if ( $testIncompleteCount > 0 ) {
		$feedbackGenerator->print( <<EOF );
<p>For some reason <b>$testIncompleteCount</b> (of $testMethodsCount,
<font color="#ee00bb">$testIncompletePercent%</font>) tests cannot be completed.</p>
<p>Double check that you have carefully followed all initial conditions
requested in the assignment in setting up your solution, and that you
have also met all requirements for a complete solution in the final
state of your program.
</p>
EOF
	}
}
$feedbackGenerator->endFeedbackSection();
$feedbackGenerator->close;

# Instructor's test log
# ---------
if ( -f $instrLog and -s $instrLog ) {
	$reportCount++;
	$cfg->setProperty( "report${reportCount}.file",     $instrLogRelative );
	$cfg->setProperty( "report${reportCount}.mimeType", "text/html" );
}

$cfg->setProperty( 'instructor.test.executed', $testMethodsCount );
$cfg->setProperty( 'instructor.test.passed',   $testPassedCount );
$cfg->setProperty( 'instructor.test.failed',   $testFailedCount );
$cfg->setProperty( 'instructor.test.passRate',
	sprintf( "%.2f", $testPassedCount / $testMethodsCount ) );
$cfg->setProperty( 'instructor.test.allPass',
	$testPassedCount == $testMethodsCount ? "1" : "0" );
$cfg->setProperty( 'instructor.test.allFail',
	$testFailedCount == $testMethodsCount ? "1" : "0" );
$cfg->setProperty( 'outcomeProperties', '("instructor.test.results")' );

my $runtimeScore =
  $maxCorrectnessScore *
  ( ( $testMethodsCount - ( $testFailedCount + $testIncompleteCount ) ) /
	  $testMethodsCount );

my $scoreToTenths = int( $runtimeScore * 10 + 0.5 ) / 10;

# dettaglio dei tests falliti
# ---
if (@failedDetails) {
	my $testFailedDetails = "";
	my $feedbackGenerator = new Web_CAT::FeedbackGenerator($failLog);
	$feedbackGenerator->startFeedbackSection("Failed Tests Details");
	$feedbackGenerator->print("<center><table style=\"width: center\">");

	for my $j ( 0 .. $#failedDetails ) {
		my $method  = $failedDetails[$j]{method};
		my $details = $failedDetails[$j]{details};

		my $k = $j + 1;
		$feedbackGenerator->print( <<EOF );
<tr>
	<th style="text-align: center">$method ($k)</th>
</tr>
<tr>
	<td><pre style="width: center">$details</pre></td>
</tr>
			
EOF
	}
	$feedbackGenerator->print("</table></center>");
	$feedbackGenerator->endFeedbackSection();
	$feedbackGenerator->close;

	$reportCount++;
	$cfg->setProperty( "report${reportCount}.file",     $failLogRelative );
	$cfg->setProperty( "report${reportCount}.mimeType", "text/html" );

}

#=============================================================================
# generate score explanation for student
#=============================================================================

my $instructorCasesPercent = "";
if ( $testIncompleteCount == $testMethodsCount ) {
	$instructorCasesPercent = "<font color=\"#ee00bb\">unknown</font>";
}
else {
	$instructorCasesPercent = "$testPassedPercent%";
}
$feedbackGenerator = new Web_CAT::FeedbackGenerator($explanation);
$feedbackGenerator->startFeedbackSection("Interpreting Your Score");
$feedbackGenerator->print( <<EOF );
<p>Your score is based on the following factors (shown here rounded to
the nearest percent):</p>
<table style="border:none">
<tr><td><b>Problem Coverage:</b></td>
<td class="n">$instructorCasesPercent</td>
<td>(how much of the problem your solution/tests cover)</td></tr>
</table>
<p>Your Correctness/Testing score is calculated this way:</p>
<p>
	<table style="border:0">
		<tr>
			<td style="text-align: right">Score = </td>
			<td style="text-align: center">maxCorrectnessScore</td>
			<td style="text-align: center"> * { </td>
			<td style="text-align: center">[ testMethodsCount - ( testFailedCount + testIncompleteCount ) ]</td>
			<td style="text-align: center"> / </td>
			<td style="text-align: center">testMethodsCount</td>
			<td> } =</td>
		</tr>
		<tr>
			<td style="text-align: right">= </td>
			<td style="text-align: center">$maxCorrectnessScore</td>
			<td style="text-align: center"> * ( </td>
			<td style="text-align: center">$testPassedCount</td>
			<td style="text-align: center"> / </td>
			<td style="text-align: center">$testMethodsCount</td>
			<td> ) = $runtimeScore.</td>
		</tr>
	</table>
</p>
<p>Note that full-precision (unrounded) percentages are used to calculate
your score.</p>
EOF
$feedbackGenerator->endFeedbackSection();
$feedbackGenerator->close;
$reportCount++;
$cfg->setProperty( "report${reportCount}.file",     $explanationRelative );
$cfg->setProperty( "report${reportCount}.mimeType", "text/html" );

#=============================================================================
# generate HTML versions of source files
#=============================================================================


chdir($workingDir);
my $b = new Web_CAT::Beautifier;
foreach my $f (@fileNames) {
	$b->{codeMessages} = \%codeMessages;
	$b->beautify( $f, $resultDir, 'html', \$numCodeMarkups, undef, $cfg );
}
$cfg->setProperty( 'numCodeMarkups', $numCodeMarkups );

#=============================================================================
# Use CLOC to calculate lines of code statistics
#=============================================================================

my @cloc_files = ();
for my $i ( 1 .. $numCodeMarkups ) {
	my $cloc_file = $cfg->getProperty( "codeMarkup${i}.sourceFileName", undef );
	push @cloc_files, $cloc_file if defined $cloc_file;
}

print "Passing these files to CLOC: @cloc_files\n" if $debug;

if (@cloc_files) {
	my $cloc = new Web_CAT::CLOC;
	$cloc->execute(@cloc_files);

	for my $i ( 1 .. $numCodeMarkups ) {
		my $cloc_file =
		  $cfg->getProperty( "codeMarkup${i}.sourceFileName", undef );

		my $cloc_metrics = $cloc->fileMetrics($cloc_file);
		next unless defined $cloc_metrics;

		$cfg->setProperty( "codeMarkup${i}.loc",
			$cloc_metrics->{blank} +
			  $cloc_metrics->{comment} +
			  $cloc_metrics->{code} );
		$cfg->setProperty( "codeMarkup${i}.ncloc",
			$cloc_metrics->{blank} + $cloc_metrics->{code} );
	}
}

#=============================================================================
# Update and rewrite properties to reflect status
#=============================================================================

$cfg->setProperty( "numReports",        $reportCount );
$cfg->setProperty( "score.correctness", $runtimeScore );

$cfg->save();

if ($debug) {
	print "\nFinal properties:\n-----------------\n";
	my $props = $cfg->getProperties();
	while ( ( my $key, my $value ) = each %{$props} ) {
		print $key, " => ", $value, "\n";
	}
}

exit(0);
