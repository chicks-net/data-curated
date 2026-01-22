#!/usr/bin/env perl
# analyze-megamillions.pl
# Perl version of the Mega Millions frequency analyzer
# Author: Christopher Hicks
#
# This does the same thing as the R version but in Perl, because why not?
# It analyzes which Mega Millions numbers get drawn most often, which is
# probably meaningless for predicting future drawings but fun to look at anyway.
#
# Required modules: Text::CSV_XS, Statistics::Descriptive
# Install with: cpanm Text::CSV_XS Statistics::Descriptive

use strict;
use warnings;
use lib "$ENV{HOME}/perl5/lib/perl5";
use Text::CSV_XS;
use Statistics::Descriptive;

# Read the Mega Millions data
print "Reading Mega Millions data...\n";

my $csv_file = "../Lottery_Mega_Millions_Winning_Numbers__Beginning_2002.csv";
my $csv = Text::CSV_XS->new({ binary => 1, auto_diag => 1 });

open my $fh, "<:encoding(utf8)", $csv_file or die "Cannot open $csv_file: $!";

# Read header row
my $header = $csv->getline($fh);

# Track drawing count and date range
my $drawing_count = 0;
my ($min_date, $max_date);

# Hash to count frequency of each number
my %main_freq;
my %mega_ball_freq;

# Process each row
while (my $row = $csv->getline($fh)) {
    my ($draw_date, $winning_numbers, $mega_ball, $multiplier) = @$row;

    $drawing_count++;

    # Track date range
    $min_date = $draw_date if !defined $min_date || $draw_date lt $min_date;
    $max_date = $draw_date if !defined $max_date || $draw_date gt $max_date;

    # Parse the winning numbers (space-separated)
    my @numbers = split /\s+/, $winning_numbers;
    foreach my $num (@numbers) {
        next if $num eq '';  # Skip empty strings
        $main_freq{int($num)}++;  # Convert to integer to strip leading zeros
    }

    # Count Mega Ball
    $mega_ball_freq{int($mega_ball)}++ if defined $mega_ball && $mega_ball ne '';
}

close $fh;

print sprintf("Loaded %d drawings from %s to %s\n",
              $drawing_count, $min_date, $max_date);

# Sort main numbers by frequency (descending)
my @main_sorted = sort { $main_freq{$b} <=> $main_freq{$a} || $a <=> $b } keys %main_freq;

# Sort Mega Balls by frequency (descending)
my @mega_ball_sorted = sort { $mega_ball_freq{$b} <=> $mega_ball_freq{$a} || $a <=> $b } keys %mega_ball_freq;

# Display results
print "\n=== MAIN NUMBERS FREQUENCY (1-70) ===\n";
print "Top 10 most frequently drawn numbers:\n";
printf "%-8s %s\n", "Number", "Count";
for my $i (0..9) {
    last if $i >= @main_sorted;
    my $num = $main_sorted[$i];
    printf "%-8d %d\n", $num, $main_freq{$num};
}

print "\nBottom 10 least frequently drawn numbers:\n";
printf "%-8s %s\n", "Number", "Count";
my $start = @main_sorted - 10;
$start = 0 if $start < 0;
for my $i ($start..$#main_sorted) {
    my $num = $main_sorted[$i];
    printf "%-8d %d\n", $num, $main_freq{$num};
}

print "\n=== MEGA BALL FREQUENCY (1-25) ===\n";
print "Top 10 most frequently drawn Mega Balls:\n";
printf "%-8s %s\n", "Number", "Count";
for my $i (0..9) {
    last if $i >= @mega_ball_sorted;
    my $num = $mega_ball_sorted[$i];
    printf "%-8d %d\n", $num, $mega_ball_freq{$num};
}

# Calculate statistics
my $main_stats = Statistics::Descriptive::Full->new();
$main_stats->add_data(values %main_freq);

my $mega_ball_stats = Statistics::Descriptive::Full->new();
$mega_ball_stats->add_data(values %mega_ball_freq);

print "\n=== SUMMARY STATISTICS ===\n";
printf "Main Numbers - Mean frequency: %.1f\n", $main_stats->mean();
printf "Main Numbers - Median frequency: %.1f\n", $main_stats->median();
printf "Main Numbers - Std Dev: %.1f\n", $main_stats->standard_deviation();
printf "\nMega Ball - Mean frequency: %.1f\n", $mega_ball_stats->mean();
printf "Mega Ball - Median frequency: %.1f\n", $mega_ball_stats->median();
printf "Mega Ball - Std Dev: %.1f\n", $mega_ball_stats->standard_deviation();

# Save results to CSV files (with -perl suffix to avoid overwriting R output)
print "\n=== OUTPUT FILES ===\n";

# Main numbers frequency CSV
my $main_csv_file = "megamillions-main-numbers-frequency-perl.csv";
open my $main_out, ">:encoding(utf8)", $main_csv_file or die "Cannot open $main_csv_file: $!";
my $main_csv_writer = Text::CSV_XS->new({ binary => 1, eol => "\n" });

$main_csv_writer->print($main_out, ["Number", "Count"]);
foreach my $num (sort { $main_freq{$b} <=> $main_freq{$a} || $a <=> $b } keys %main_freq) {
    $main_csv_writer->print($main_out, [$num, $main_freq{$num}]);
}
close $main_out;
print "Main numbers frequency saved to: $main_csv_file\n";

# Mega Ball frequency CSV
my $mega_ball_csv_file = "megamillions-mega-ball-frequency-perl.csv";
open my $mega_ball_out, ">:encoding(utf8)", $mega_ball_csv_file or die "Cannot open $mega_ball_csv_file: $!";
my $mega_ball_csv_writer = Text::CSV_XS->new({ binary => 1, eol => "\n", quote_space => 0 });

$mega_ball_csv_writer->print($mega_ball_out, ["Mega Ball", "Count"]);
foreach my $num (sort { $mega_ball_freq{$b} <=> $mega_ball_freq{$a} || $a <=> $b } keys %mega_ball_freq) {
    $mega_ball_csv_writer->print($mega_ball_out, [$num, $mega_ball_freq{$num}]);
}
close $mega_ball_out;
print "Mega Ball frequency saved to: $mega_ball_csv_file\n";

print "\nAnalysis complete!\n";
print "\nNote: This Perl version generates the same analysis as the R script\n";
print "but saves output to separate files (with -perl suffix) to avoid conflicts.\n";
print "The R script generates prettier visualizations, so use that if you want charts.\n";
