package Bio::ToolBox::Data::core;
our $VERSION = '1.30';

=head1 NAME

Bio::ToolBox::Data::core - Common functions to Bio:ToolBox::Data family

=head1 DESCRIPTION

Common methods for metadata and manipulation in a L<Bio::ToolBox::Data> 
data table and L<Bio::ToolBox::Data::Stream> file stream. This module 
should not be used directly. See the respective modules for more information.

=cut

use strict;
use Carp qw(carp cluck croak confess);
use base 'Bio::ToolBox::Data::file';
use Bio::ToolBox::db_helper qw(
	open_db_connection
	verify_or_request_feature_types
);

1;

#### Initialization and verification ###############################################

sub new {
	my $class = shift;
	
	# in case someone calls this from an established object
	if (ref($class) =~ /Bio::ToolBox/) {
		$class = ref($class);
	}
	
	# Initialize the hash structure
	my %data = (
		'program'        => undef,
		'feature'        => undef,
		'feature_type'   => undef,
		'db'             => undef,
		'gff'            => 0,
		'bed'            => 0,
		'ucsc'           => 0,
		'number_columns' => 0,
		'last_row'       => 0,
		'headers'        => 1,
		'column_names'   => [],
		'filename'       => undef,
		'basename'       => undef,
		'extension'      => undef,
		'path'           => undef,
		'comments'       => [],
		'data_table'     => [],
	);
	
	# Finished
	return bless \%data, $class;
}


sub verify {
	# this function does not rely on any self functions for two reasons
	# this is a low level integrity checker
	# this is very old code from before the days of an OO API of Bio::ToolBox
	my $self = shift;
	carp "verify is a read only method" if @_;
	
	# check for data table
	unless (
		defined $self->{'data_table'} and 
		ref $self->{'data_table'} eq 'ARRAY'
	) {
		carp " No data table in passed data structure!";
		return;
	}
	
	# check for last row index
	if (defined $self->{'last_row'}) {
		my $number = scalar( @{ $self->{'data_table'} } ) - 1;
		if ($self->{'last_row'} != $number) {
			carp " data table last_row index [$number] doesn't match " . 
				"metadata value [" . $self->{'last_row'} . "]!\n";
			# fix it for them
			$self->{'last_row'} = $number;
		}
	}
	else {
		# define it for them
		$self->{'last_row'} = 
			scalar( @{ $self->{'data_table'} } ) - 1;
	}
	
	# check for consistent number of columns
	if (defined $self->{'number_columns'}) {
		my $number = $self->{'number_columns'};
		my @problems;
		my $too_low = 0;
		my $too_high = 0;
		for (my $row = 0; $row <= $self->{'last_row'}; $row++) {
			my $count = scalar @{ $self->{'data_table'}->[$row] };
			if ($count != $number) {
				push @problems, $row;
				$too_low++ if $count < $number;
				$too_high++ if $count > $number;
				while ($count < $number) {
					# we can sort-of-fix this problem
					$self->{'data_table'}->[$row][$count] = '.';
					$count++;
				}
			}
		}
		if ($too_low) {
			carp " $too_low rows in data table had fewer than expected columns!\n" . 
				 "  padded rows " . join(',', @problems) . " with null values\n";
		}
		if ($too_high) {
			carp " $too_high rows in data table had more columns than expected!\n" . 
				" rows " . join(',', @problems) . "\n";
			return;
		}
	}
	else {
		$self->{'number_columns'} = 
			scalar @{ $self->{'data_table'}->[0] };
	}
	
	# check metadata
	for (my $i = 0; $i < $self->{'number_columns'}; $i++) {
		unless (
			$self->{$i}{'name'} eq 
			$self->{'data_table'}->[0][$i]
		) {
			carp " incorrect or missing metadata!  Column header names don't" .
				" match metadata name values for index $i!" . 
				" compare '" . $self->{$i}{'name'} . "' with '" .
				$self->{'data_table'}->[0][$i] . "'\n";
			return;
		}
	}
	
	# check for proper gff structure
	if ($self->{'gff'}) {
		# if any of these checks fail, we will reset the gff version to 
		# the default of 0, or no gff
		my $gff_check = 1; # start with assumption it is true
		
		# check number of columns
		if ($self->{'number_columns'} != 9) {
			$gff_check = 0;
		}
		
		# check column indices
		if (
			# column 0 should look like chromosome
			exists $self->{0} and
			$self->{0}{'name'} !~ 
			m/^#?(?:chr|chromo|seq|refseq|ref_seq|seq|seq_id)/i
		) {
			$gff_check = 0;
		}
		if (
			# column 3 should look like start
			exists $self->{3} and
			$self->{3}{'name'} !~ m/start|pos|position/i
		) {
			$gff_check = 0;
		}
		if (
			# column 4 should look like end
			exists $self->{4} and
			$self->{4}{'name'} !~ m/stop|end|pos|position/i
		) {
			$gff_check = 0;
		}
		if (
			# column 6 should look like strand
			exists $self->{6} and
			$self->{6}{'name'} !~ m/strand/i
		) {
			$gff_check = 0;
		}
		
		# check integers
		$gff_check = 0 unless $self->_column_is_integers(3,4);
		
		# update gff value as necessary
		if ($gff_check == 0) {
			# reset metadata
			$self->{'gff'} = 0;
			$self->{'headers'} = 1;
			
			# remove the AUTO key from the metadata
			for (my $i = 0; $i < $self->{'number_columns'}; $i++) {
				if (exists $self->{$i}{'AUTO'}) {
					delete $self->{$i}{'AUTO'};
				}
			}
		}
	}
	
	# check for proper BED structure
	if ($self->{'bed'}) {
		# if any of these checks fail, we will reset the bed flag to 0
		# to make it not a bed file format
		my $bed_check = 1; # start with assumption it is correct
		
		# check number of columns
		if (
			$self->{'number_columns'} < 3 and 
			$self->{'number_columns'} > 12 
		) {
			$bed_check = 0;
		}
		
		# check column index names
		if (
			exists $self->{0} and
			$self->{0}{'name'} !~ 
			m/^#?(?:chr|chromo|seq|refseq|ref_seq|seq|seq_id)/i
		) {
			$bed_check = 0;
		}
		if (
			exists $self->{1} and
			$self->{1}{'name'} !~ m/start|pos|position/i
		) {
			$bed_check = 0;
		}
		if (
			exists $self->{2} and
			$self->{2}{'name'} !~ m/stop|end|pos|position/i
		) {
			$bed_check = 0;
		}
		if (
			exists $self->{5} and
			$self->{5}{'name'} !~ m/strand/i
		) {
			$bed_check = 0;
		}
		
		# coordinates are integers
		$bed_check = 0 unless $self->_column_is_integers(1,2);
		
		# reset the BED tag value as appropriate
		if ($bed_check) {
			$self->{'bed'} = $self->{'number_columns'};
		}
		else {
			# reset metadata
			$self->{'bed'} = 0;
			$self->{'headers'} = 1;
			
			# remove the AUTO key from the metadata
			for (my $i = 0; $i < $self->{'number_columns'}; $i++) {
				if (exists $self->{$i}{'AUTO'}) {
					delete $self->{$i}{'AUTO'};
				}
			}
		}
	}
	
	# check refFlat or genePred gene structure
	if ($self->{'ucsc'}) {
		# if any of these checks fail, we will reset the extension
		my $ucsc_check = 1; # start with assumption it is correct
		
		# check number of columns
		my $colnumber = $self->{number_columns};
		if ($colnumber == 16) {
			# bin name chrom strand txStart txEnd cdsStart cdsEnd 
			# exonCount exonStarts exonEnds score name2 cdsStartSt 
			# cdsEndStat exonFrames
			$ucsc_check = 0 unless $self->{2}{name} =~ 
				/^#?(?:chr|chromo|seq|refseq|ref_seq|seq|seq_id)/i;
			$ucsc_check = 0 unless $self->{4}{name} =~ /start|position/i;
			$ucsc_check = 0 unless $self->{5}{name} =~ /stop|end|position/i;
			$ucsc_check = 0 unless $self->{6}{name} =~ /start|position/i;
			$ucsc_check = 0 unless $self->{7}{name} =~ /stop|end|position/i;
			$ucsc_check = 0 unless $self->_column_is_integers(4,5,6,7,8);
		}		
		elsif ($colnumber == 15 or $colnumber == 12) {
			# name chrom strand txStart txEnd cdsStart cdsEnd 
			# exonCount exonStarts exonEnds score name2 cdsStartSt 
			# cdsEndStat exonFrames
			# or 
			# name chrom strand txStart txEnd cdsStart cdsEnd 
			# exonCount exonStarts exonEnds proteinID alignID
			$ucsc_check = 0 unless $self->{1}{name} =~ 
				/^#?(?:chr|chromo|seq|refseq|ref_seq|seq|seq_id)/i;
			$ucsc_check = 0 unless $self->{3}{name} =~ /start|position/i;
			$ucsc_check = 0 unless $self->{4}{name} =~ /stop|end|position/i;
			$ucsc_check = 0 unless $self->{5}{name} =~ /start|position/i;
			$ucsc_check = 0 unless $self->{6}{name} =~ /stop|end|position/i;
			$ucsc_check = 0 unless $self->_column_is_integers(3,4,5,6,7);
		}		
		elsif ($colnumber == 11) {
			# geneName transcriptName chrom strand txStart txEnd 
			# cdsStart cdsEnd exonCount exonStarts exonEnds
			$ucsc_check = 0 unless $self->{2}{name} =~ 
				/^#?(?:chr|chromo|seq|refseq|ref_seq|seq|seq_id)/i;
			$ucsc_check = 0 unless $self->{4}{name} =~ /start|position/i;
			$ucsc_check = 0 unless $self->{5}{name} =~ /stop|end|position/i;
			$ucsc_check = 0 unless $self->{6}{name} =~ /start|position/i;
			$ucsc_check = 0 unless $self->{7}{name} =~ /stop|end|position/i;
			$ucsc_check = 0 unless $self->_column_is_integers(4,5,6,7,8);
		}		
		elsif ($colnumber == 10) {
			# name chrom strand txStart txEnd cdsStart cdsEnd 
			# exonCount exonStarts exonEnds
			$ucsc_check = 0 unless $self->{1}{name} =~ 
				/^#?(?:chr|chromo|seq|refseq|ref_seq|seq|seq_id)/i;
			$ucsc_check = 0 unless $self->{3}{name} =~ /start|position/i;
			$ucsc_check = 0 unless $self->{4}{name} =~ /stop|end|position/i;
			$ucsc_check = 0 unless $self->{5}{name} =~ /start|position/i;
			$ucsc_check = 0 unless $self->{6}{name} =~ /stop|end|position/i;
			$ucsc_check = 0 unless $self->_column_is_integers(3,4,5,6,7);
		}
		else {
			$ucsc_check = 0;
		}

		if ($ucsc_check == 0) {
			# failed the check
			my $ext = $self->{'extension'};
			$self->{'filename'} =~ s/$ext/.txt/;
			$self->{'extension'} = '.txt';
			$self->{'ucsc'} = 0;
			
			# remove the AUTO key
			for (my $i = 0; $i < $self->{'number_columns'}; $i++) {
				if (exists $self->{$i}{'AUTO'}) {
					delete $self->{$i}{'AUTO'};
				}
			}
		}	
	}
	
	# check proper SGR file structure
	if (exists $self->{'extension'} and 
		defined $self->{'extension'} and
		$self->{'extension'} =~ /sgr/i
	) {
		# there is no sgr field in the data structure
		# so we're just checking for the extension
		# we will change the extension as necessary if it doesn't conform
		if (
			$self->{'number_columns'} != 3 or
			$self->{0}{'name'} !~ /^chr|seq|ref/i or
			$self->{1}{'name'} !~ /^start|position/i or 
			not $self->_column_is_integers(1)
		) {
			# doesn't smell like a SGR file
			# change the extension so the write subroutine won't think it is
			# make it a text file
			$self->{'extension'} =~ s/sgr/txt/i;
			$self->{'filename'}  =~ s/sgr/txt/i;
			$self->{'headers'} = 1;
			
			# remove the AUTO key from the metadata
			for (my $i = 0; $i < $self->{'number_columns'}; $i++) {
				if (exists $self->{$i}{'AUTO'}) {
					delete $self->{$i}{'AUTO'};
				}
			}
		}
	}
	
	# if we haven't made it here yet, then there was a problem
	return 1;
}

# internal method to check if a column is nothing but integers, i.e. start, stop
sub _column_is_integers {
	my $self = shift;
	my @index = @_;
	for my $row (1 .. $self->{last_row}) {
		for my $i (@index) {
			return 0 unless ($self->{data_table}->[$row][$i] =~ /^\d+$/);
		}
	}
	return 1;
}





#### Database methods ##############################################################

sub open_database {
	my $self = shift;
	my $force = shift || 0;
	return unless $self->{db};
	if (exists $self->{db_connection}) {
		return $self->{db_connection} unless $force;
	}
	my $db = open_db_connection($self->{db}, $force);
	return unless $db;
	$self->{db_connection} = $db;
	return $db;
}

sub verify_dataset {
	my $self = shift;
	my $dataset = shift;
	my $database = shift; # name or object?
	return unless $dataset;
	if (exists $self->{verfied_dataset}{$dataset}) {
		return $self->{verfied_dataset}{$dataset};
	}
	else {
		if ($dataset =~ /^(?:file|http|ftp)/) {
			# local or remote file already verified?
			$self->{verfied_dataset}{$dataset} = $dataset;
			return $dataset;
		}
		$database ||= $self->open_database;
		my ($verified) = verify_or_request_feature_types(
			# normally returns an array of verified features, we're only checking one
			db      => $database,
			feature => $dataset,
		);
		if ($verified) {
			$self->{verfied_dataset}{$dataset} = $verified;
			return $verified;
		}
	}
	return;
}



#### Column Manipulation ####

sub delete_column {
	my $self = shift;
	
	# check for Stream
	if (ref $self eq 'Bio::ToolBox::Data::Stream') {
		unless ($self->mode) {
			cluck "We have a read-only Stream object, cannot add columns";
			return;
		}
		if (defined $self->{fh}) {
			# Stream file handle is opened
			cluck "Cannot modify columns when a Stream file handle is opened!";
			return;
		}
	}
	unless (@_) {
		cluck "must provide a list";
		return;
	}
	
	my @deletion_list = sort {$a <=> $b} @_;
	my @retain_list; 
	for (my $i = 0; $i < $self->number_columns; $i++) {
		# compare each current index with the first one in the list of 
		# deleted indices. if it matches, delete. if not, keep
		if ( $i == $deletion_list[0] ) {
			# this particular index should be deleted
			shift @deletion_list;
		}
		else {
			# this particular index should be kept
			push @retain_list, $i;
		}
	}
	return $self->reorder_column(@retain_list);
}

sub reorder_column {
	my $self = shift;
	
	# check for Stream
	if (ref $self eq 'Bio::ToolBox::Data::Stream') {
		unless ($self->mode) {
			cluck "We have a read-only Stream object, cannot add columns";
			return;
		}
		if (defined $self->{fh}) {
			# Stream file handle is opened
			cluck "Cannot modify columns when a Stream file handle is opened!";
			return;
		}
	}
	
	# reorder data table
	unless (@_) {
		carp "must provide a list";
		return;
	}
	my @order = @_;
	for (my $row = 0; $row <= $self->last_row; $row++) {
		my @old = $self->row_values($row);
		my @new = map { $old[$_] } @order;
		splice( @{ $self->{data_table} }, $row, 1, \@new);
	}
	
	# reorder metadata
	my %old_metadata;
	for (my $i = 0; $i < $self->number_columns; $i++) {
		# copy the metadata info hash into a temporary hash
		$old_metadata{$i} = $self->{$i};
		delete $self->{$i}; # delete original
	}
	for (my $i = 0; $i < scalar(@order); $i++) {
		# now copy back from the old_metadata into the main data hash
		# using the new index number in the @order array
		# must regenerate the hash, not just link to the old anonymous hash, in 
		# case we're duplicating columns
		$self->{$i} = {};
		foreach my $k (keys %{ $old_metadata{$order[$i]} }) {
			$self->{$i}{$k} = $old_metadata{$order[$i]}{$k};
		}
		# assign new index number
		$self->{$i}{'index'} = $i;
	}
	$self->{'number_columns'} = scalar @order;
	delete $self->{column_indices} if exists $self->{column_indices};
	return 1;
}



#### General Metadata ####

sub feature {
	my $self = shift;
	if (@_) {
		$self->{feature} = shift;
	}
	return $self->{feature};
}

sub feature_type {
	my $self = shift;
	carp "feature_type is a read only method" if @_;
	if (defined $self->{feature_type}) {
		return $self->{feature_type};
	}
	my $feature_type;
	if (defined $self->chromo_column and defined $self->start_column) {
		$feature_type = 'coordinate';
	}
	elsif (defined $self->id_column or 
		( defined $self->type_column and defined $self->name_column ) or 
		( defined $self->feature and defined $self->name_column )
	) {
		$feature_type = 'named';
	}
	else {
		$feature_type = 'unknown';
	}
	$self->{feature_type} = $feature_type;
	return $feature_type;
}

sub program {
	my $self = shift;
	if (@_) {
		$self->{program} = shift;
	}
	return $self->{program};
}

sub database {
	my $self = shift;
	if (@_) {
		$self->{db} = shift;
		if (exists $self->{db_connection}) {
			my $db = open_db_connection($self->{db});
			$self->{db_connection} = $db if $db;
		}
	}
	return $self->{db};
}

sub gff {
	my $self = shift;
	if ($_[0] and $_[0] =~ /^[123]/) {
		$self->{gff} = $_[0];
	}
	return $self->{gff};
}

sub bed {
	my $self = shift;
	if ($_[0] and $_[0] =~ /^\d+/) {
		$self->{bed} = $_[0];
	}
	return $self->{bed};
}

sub ucsc {
	my $self = shift;
	if ($_[0] and $_[0] =~ /^\d+$/) {
		$self->{ucsc} = $_[0];
	}
	return $self->{ucsc};
}

sub number_columns {
	my $self = shift;
	carp "number_columns is a read only method" if @_;
	return $self->{number_columns};
}

sub last_row {
	my $self = shift;
	carp "last_row is a read only method" if @_;
	return $self->{last_row};
}

sub filename {
	my $self = shift;
	carp "filename is a read only method. Use add_file_metadata()." if @_;
	return $self->{filename};
}

sub basename {
	my $self = shift;
	carp "basename is a read only method. Use add_file_metadata()." if @_;
	return $self->{basename};
}

sub path {
	my $self = shift;
	carp "path is a read only method. Use add_file_metadata()." if @_;
	return $self->{path};
}

sub extension {
	my $self = shift;
	carp "extension() is a read only method. Use add_file_metadata()." if @_;
	return $self->{extension};
}



#### General Comments ####

sub comments {
	my $self = shift;
	my @comments = @{ $self->{comments} };
	foreach (@comments) {s/[\r\n]+//g}
	# comments are not chomped when loading
	# side effect of dealing with rare commented header lines with null values at end
	return @comments;
}

sub add_comment {
	my $self = shift;
	my $comment = shift or return;
	# comment is not required to be prefixed with "# ", it will be added when saving
	push @{ $self->{comments} }, $comment;
	return 1;
}

sub delete_comment {
	my $self = shift;
	my $index = shift;
	if (defined $index) {
		eval {splice @{$self->{comments}}, $index, 1};
	}
	else {
		$self->{comments} = [];
	}
}



#### Column Metadata ####

sub list_columns {
	my $self = shift;
	carp "list_columns is a read only method" if @_;
	my @list;
	for (my $i = 0; $i < $self->number_columns; $i++) {
		push @list, $self->{$i}{'name'};
	}
	return wantarray ? @list : \@list;
}

sub name {
	my $self = shift;
	my ($index, $new_name) = @_;
	return unless defined $index;
	return unless exists $self->{$index}{name};
	if (defined $new_name) {
		$self->{$index}{name} = $new_name;
		if (exists $self->{data_table}) {
			$self->{data_table}->[0][$index] = $new_name;
		}
		elsif (exists $self->{column_names}) {
			$self->{column_names}->[$index] = $new_name;
		}
	}
	return $self->{$index}{name};
}

sub metadata {
	my $self = shift;
	my ($index, $key, $value) = @_;
	return unless defined $index;
	return unless exists $self->{$index};
	if ($key and $key eq 'name') {
		return $self->name($index, $value);
	}
	if ($key and defined $value) { 
		# we are setting a new value
		$self->{$index}{$key} = $value;
		return $value;
	}
	elsif ($key and not defined $value) {
		if (exists $self->{$index}{$key}) {
			# retrieve a value
			return $self->{$index}{$key};
		}
		else {
			# key does not exist
			return;
		}
	}
	else {
		my %hash = %{ $self->{$index} };
		return wantarray ? %hash : \%hash;
	}
}

sub delete_metadata {
	my $self = shift;
	my ($index, $key) = @_;
	return unless defined $index;
	if (defined $key) {
		if (exists $self->{$index}{$key}) {
			return delete $self->{$index}{$key};
		}
	}
	else {
		# user wants to delete the metadata
		# but we need to keep the basics name and index
		foreach my $key (keys %{ $self->{$index} }) {
			next if $key eq 'name';
			next if $key eq 'index';
			delete $self->{$index}{$key};
		}
	}
}

sub copy_metadata {
	my ($self, $source, $target) = @_;
	return unless (exists $self->{$source}{name} and exists $self->{$target}{name});
	my $md = $self->metadata($source);
	delete $md->{name};
	delete $md->{'index'};
	delete $md->{'AUTO'} if exists $md->{'AUTO'}; # presume this is no longer auto index
	foreach (keys %$md) {
		$self->{$target}{$_} = $md->{$_};
	}
	return 1;
}



#### Column Indices ####

sub find_column {
	my ($self, $name) = @_;
	return unless $name;
	
	# the $name variable will be used as a regex in identifying the name
	# fix it so that it will possible accept a # character at the beginning
	# without a following space, in case the first column has a # prefix
	# also place the remainder of the text in a non-capturing parentheses for 
	# grouping purposes while maintaining the anchors
	$name =~ s/ \A (\^?) (.+) (\$?)\Z /$1#?(?:$2)$3/x;
	
	# walk through each column index
	my $index;
	for (my $i = 0; $i < $self->{'number_columns'}; $i++) {
		# check the names of each column
		if ($self->{$i}{'name'} =~ /$name/i) {
			$index = $i;
			last;
		}
	}
	return $index;
}

sub _find_column_indices {
	my $self = shift;
	# these are hard coded index name regex to accomodate different possibilities
	# these do not include parentheses for grouping
	# non-capturing parentheses will be added later in the sub for proper 
	# anchoring and grouping - long story why, don't ask
	my $name   = $self->find_column('^name|geneName|transcriptName|geneid|id|alias');
	my $type   = $self->find_column('^type|class|primary_tag');
	my $id     = $self->find_column('^primary_id');
	my $chromo = $self->find_column('^chr|seq|ref|ref.?seq');
	my $start  = $self->find_column('^start|position|pos|txStart$');
	my $stop   = $self->find_column('^stop|end|txEnd');
	my $strand = $self->find_column('^strand');
	$self->{column_indices} = {
		'name'      => $name,
		'type'      => $type,
		'id'        => $id,
		'seq_id'    => $chromo,
		'chromo'    => $chromo,
		'start'     => $start,
		'stop'      => $stop,
		'end'       => $stop,
		'strand'    => $strand,
	};
	return 1;
}

sub chromo_column {
	my $self = shift;
	carp "chromo_column is a read only method" if @_;
	$self->_find_column_indices unless exists $self->{column_indices};
	return $self->{column_indices}{chromo};
}

sub start_column {
	my $self = shift;
	carp "start_column is a read only method" if @_;
	$self->_find_column_indices unless exists $self->{column_indices};
	return $self->{column_indices}{start};
}

sub stop_column {
	my $self = shift;
	carp "stop_column is a read only method" if @_;
	$self->_find_column_indices unless exists $self->{column_indices};
	return $self->{column_indices}{stop};
}

sub end_column {
	return shift->stop_column;
}

sub strand_column {
	my $self = shift;
	carp "strand_column is a read only method" if @_;
	$self->_find_column_indices unless exists $self->{column_indices};
	return $self->{column_indices}{strand};
}

sub name_column {
	my $self = shift;
	carp "name_column is a read only method" if @_;
	$self->_find_column_indices unless exists $self->{column_indices};
	return $self->{column_indices}{name};
}

sub type_column {
	my $self = shift;
	carp "type_column is a read only method" if @_;
	$self->_find_column_indices unless exists $self->{column_indices};
	return $self->{column_indices}{type};
}

sub id_column {
	my $self = shift;
	carp "id_column is a read only method" if @_;
	$self->_find_column_indices unless exists $self->{column_indices};
	return $self->{column_indices}{id};
}

__END__

=head1 METHODS REFERENCE

For reference only. Please use L<Bio::ToolBox::Data>

=over 4

=item new

Generate new object. 

=item verify

Verify the integrity of the Data object. Checks multiple things, 
including metadata, table integrity (consistent number of rows and 
columns), and special file format structure.

=item open_database

Open the database that is listed in the metadata. Returns the 
database connection. Pass a true value to force a new database 
connection to be opened, rather than returning a cached connection 
object (useful when forking).

=item verify_dataset($dataset)

Verifies the existence of a dataset or data file before collecting 
data from it. Multiple datasets may be verified. This is a convenience 
method to Bio::ToolBox::db_helper::verify_or_request_feature_types().

=item delete_column(@indices)

Delete one or more columns in a data table.

=item reorder_column(@indices)

Reorder the columns in a data table. Allows for skipping (deleting) and 
duplicating columns.

=item feature

Returns or sets the string of the feature name listed in the metadata. 

=item feature_type

Returns "named", "coordinate", or "unknown" based on what kind of feature 
is present in the data table.

=item program

Returns or sets the program string in the metadata.

=item database

Returns or sets the name of the database in the metadata.

=item gff

Returns or sets the GFF version value in the metadata.

=item bed

Returns or sets the number of BED columns in the metadata. 

=item ucsc

Returns or sets the number of columns in a UCSC-type file 
format, including genePred and refFlat.

=item number_columns

Returns the number of columns in the data table.

=item last_row

Returns the array index of the last row in the data table.

=item filename

Returns the complete filename listed in the metadata.

=item basename

Returns the base name of the filename listed in the metadata.

=item path

Returns the path portion of the filename listed in the metadata.

=item extension

Returns the recognized extension of the filename listed in the metadata.

=item comments

Returns an array of comment lines present in the metadata.

=item add_comment($string)

Adds a string to the list of comments to be included in the metadata.

=item delete_comment($index)

Deletes the indicated array index from the metadata comments array.

=item list_columns

Returns an array of the column names

=item name($index)

=item name($index, $newname)

Returns or sets the name of the column.

=item metadata($index, $key)

=item metadata($index, $key, $value)

Returns or sets the metadata key/value pair for a specific column.

=item delete_metadata($index, $key)

Deletes the metadata key for a column.
 
=item copy_metadata($source, $target)

Copies the metadata values from one column to another column.

=item find_column("string")

Returns the column index for the column with the specified name. Name 
searches are case insensitive and can tolerate a # prefix character. 
The first match is returned.

=item chromo_column

Returns the index of the column that best represents the chromosome column.

=item start_column

Returns the index of the column that best represents the start, position, 
or transcription start column.

=item stop_column

=item end_column

Returns the index of the column that best represents the stop or end 
column. 

=item strand_column

Returns the index of the column that best represents the strand.

=item name_column

Returns the index of the column that best represents the name.

=item type_column

Returns the index of the column that best represents the type.

=item id_column

Returns the index of the column that represents the Primary_ID 
column used in databases.

=back

=head1 AUTHOR

 Timothy J. Parnell, PhD
 Dept of Oncological Sciences
 Huntsman Cancer Institute
 University of Utah
 Salt Lake City, UT, 84112

This package is free software; you can redistribute it and/or modify
it under the terms of the Artistic License 2.0.  