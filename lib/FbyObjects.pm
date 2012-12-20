use Modern::Perl;
use utf8::all;

package ImageInstance;
use Moose;
has 'id' => (is => 'rw', isa => 'Int');
has 'image_id' => (is => 'rw', isa => 'Int');
has 'filename' => (is => 'rw', isa => 'Str');
has 'width' => (is => 'rw', isa => 'Int');
has 'height' => (is => 'rw', isa => 'Int');
has 'mtime' => (is => 'rw', isa => 'Int');

sub wikiname
{
	my ($self) = @_;
	my $filename = $self->filename;
	$filename =~ s%^.*[\/\!]%%;
	$filename =~ s/\d+px\-//;
	return $filename;
}

sub loadDimensions()
{
	my ($self) = @_;
	my $fullpath = $self->filename;
	print "Loading dimensions for $fullpath\n";
	my @stat = stat($self->filename);
	my $mtime = $stat[9];
	$self->mtime($mtime);

	my $mo = `jpeginfo '$fullpath'`;
	if ($mo =~ / (\d+) x (\d+) /)
	{
		$self->width($1);
		$self->height($2);
	}
	else
	{
		my $fullpath = $self->filename;
		my $mo = `mogrify -verbose '$fullpath'`;
		if ($mo =~ / (\d+)x(\d+) /)
		{
			$self->width($1);
			$self->height($2);
		}
	}
	if (defined($self->width()) && defined($self->height()))
	{
		my @stat = stat($self->filename);
		my $mtime = $stat[9];
	}
}

sub needsDimensionsLoaded()
{
	my ($self) = @_;
	my @stat = stat($self->filename);
	my $mtime = $stat[9];

#	print $self-e>filename ." - ".$mtime." / ".$self->mtime." ".$self->width."x".$self->height."\n";
    return undef unless defined($mtime);
	return ((!defined($self->mtime))
			|| $mtime > $self->mtime
			|| !(defined($self->width) && defined($self->height)))

}

sub dimensions()
{
	my ($self) = @_;
	my @ret = ($self->width, $self->height);
	return @ret	if (wantarray);
	return \@ret;
}


no Moose;
__PACKAGE__->meta->make_immutable;



package Image;
use Moose;
has 'id' => (is => 'rw', isa => 'Int');
has 'wikiname' => (is => 'rw', isa => 'Str');

has 'camera_id' => (is => 'rw', isa => 'Int');
has 'exiftime' => (is => 'rw', isa => 'ISO8601Timestamp');
has 'calctime' => (is => 'rw', isa => 'ISO8601Timestamp');
has 'latitude' => (is => 'rw', isa => 'Num');
has 'longitude' => (is => 'rw', isa => 'Num');
has 'altitude' => (is => 'rw', isa => 'Num');
has 'focallength' => (is => 'rw', isa => 'Num');
has 'focusdist' => (is => 'rw', isa => 'Num');
has 'aperture' => (is => 'rw', isa => 'Num');
has 'exposuretime' => (is => 'rw', isa => 'Num');
has 'set_flags' => (is => 'rw', isa => 'Int');

sub set_flag_keys
{
    return 
        [
         'calctime',
         'exiftime',
         'exiftime',
         'focallength',
         'exposuretime',
         'aperture',
         'focusdist',
         'latitude',
         'longitude',
         'altitude',
        ];
}


sub instances($)
{
	my ($self, $db) = @_;
	return $db->load('ImageInstance', image_id => $self->id);
}

sub _sortinstances
{
	my ($self,$db) = @_;
	my @instsunsorted = $self->instances($db);
	my @insts = sort { $b->dimensions->[0] <=> $a->dimensions->[0] } @instsunsorted;
	return @insts;
}

sub instanceslargetosmall
{
	my ($self, $db) = @_;
	return $self->_sortinstances($db);
}

sub fullsize
{
	my ($self,$db) = @_;
	my @insts = $self->_sortinstances($db);
	my $i = 0;
	$i++ while ($i < $#insts && $insts[$i]->dimensions->[0] > 1024);
	return $insts[$i];
}

sub lightboxzoom
{
	my ($self,$db) = @_;
	my @insts = $self->_sortinstances($db);
	my $i = 0;
	$i++ while ($i < $#insts && $insts[$i]->dimensions->[1] > 600);
	return $insts[$i];
}

sub thumb
{
	my ($self, $db) = @_;
	my @insts = $self->_sortinstances($db);
	return $insts[$#insts];
}



no Moose;
__PACKAGE__->meta->make_immutable;


package Camera;
use Moose;
has id => (is => 'rw', isa => 'Int');
has 'name' => (is => 'rw', isa => 'Str');

sub unique_indexes
{
	return ('name');
}

no Moose;
__PACKAGE__->meta->make_immutable;


package CameraTime;
use Moose;
has id => (is => 'rw', isa => 'Int');
has camera_id => (is => 'rw', isa => 'Int');
has 'insertiontime' => (is => 'rw', isa => 'ISO8601Timestamp');
has 'cameratime' => (is => 'rw', isa => 'ISO8601Timestamp');
has 'gpstime' => (is => 'rw', isa => 'ISO8601Timestamp');


no Moose;
__PACKAGE__->meta->make_immutable;





package WikiEntryReference;
use Moose;
has id => (is => 'rw', isa => 'Int');
has from_id => (is => 'rw', isa => 'Int');
has to_id => (is => 'rw', isa => 'Int');

no Moose;
__PACKAGE__->meta->make_immutable;


package WikiEntry;
use Moose;
has 'id' => (is => 'rw', isa => 'Int');
has inputname => (is => 'rw', isa => 'Str');
has 'wikiname' => (is => 'rw', isa => 'Str');
has _missingReferences => (is => 'rw', default => sub { {} });
has needsExternalRebuild => (is => 'rw', isa => 'Int');
has needsContentRebuild => (is => 'rw', isa => 'Int');

has _mtime => (is => 'rw', isa => 'Int');
has _ctime => (is => 'rw', isa => 'Int');
has _size => (is => 'rw', isa => 'Int');

sub initStatStuff()
{
	my ($self) = @_;
	if (defined($self->inputname))
	{
		my ($size, $mtime, $ctime) = (stat("mvs/".$self->inputname))[7,9,10];
		die "Unable to open ".$self->inputname."\n" unless (defined($mtime));
		$self->_mtime($mtime);
		$self->_ctime($ctime);
		$self->_size($size);
	}
}


sub mtime()
{
	my ($self) = @_;
	$self->initStatStuff() unless defined($self->_mtime);
	return $self->_mtime;
}

sub ctime()
{
	my ($self) = @_;
	$self->initStatStuff() unless defined($self->_ctime);
	return $self->_ctime;
}

sub size()
{
	my ($self) = @_;
	$self->initStatStuff() unless defined($self->_size);
	return $self->_size;
}


sub referencedBy()
{
	my ($self,$db) = @_;

	my @a = $db->load('WikiEntryReference', to_id => $self->id);

	my $debug = ($self->wikiname =~ /Category\:\s*10\s+Mission/);
	print "Loaded: ", join(',', @a)," to_id is ".$self->id."\n"
		if ($debug);
	my @b;
	foreach (@a)
	{
		my ($entry) = $db->load_one('WikiEntry', id => $_->from_id);
		if (defined($entry))
		{
		    print "Loaded ".$entry->wikiname." for ".$self->wikiname."\n"
			if ($debug);
		    push @b, $entry;
		}
	}
	return @b;
}


sub addReference
{
	my ($self, $ref) = @_;
	$self->references()->{$ref->wikiname} = $ref;
}


sub CanonicalName($)
{
	my ($name) = @_;
	$name =~ s/\:\s+/\:/xsg;
	$name =~ s/\s+/\ /xsg;
	$name =~ s/\.wiki$//xsg;
	return $name;
}


sub canonical_name
{
	my ($self) = @_;	
	return CanonicalName($self->inputname);
}

sub outputnameRoot
{
	my ($self) = @_;
	my $name = $self->wikiname;
	$name =~ s/ /_/g;
	return $name;
}

sub outputname
{
	my ($self) = @_;
	return $self->outputnameRoot.'.html';
}


no Moose;
__PACKAGE__->meta->make_immutable;

1;
