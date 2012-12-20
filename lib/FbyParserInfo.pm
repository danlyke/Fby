use Modern::Perl;
use utf8::all;

package FbyParserInfo;

use Moose;
has outputdir => (is => 'rw', isa => 'Str');
has stagingdir => (is => 'rw', isa => 'Str');
has sourcedir => (is => 'rw', isa => 'Str');
has db => (is => 'rw');
has suffix => (is => 'rw', isa => 'Str');
has wikiobj => (is => 'rw');
has googlemapnum => (is => 'rw', isa => 'Int');
has tagsused => (is => 'rw', default => sub { return {}; });


sub DebugPrint($@)
{
	my $self = shift;
	print join(' ', @_);
	print "\n";
}

sub WebPathFromFilename($)
{
	my ($self, $path) = @_;
	my $outputdir = $self->outputdir;
	$path =~ s/^$outputdir//;
	return $path;
}

sub ImageTagFromInstance($@)
{
	my ($self, $inst, $alt) = @_;
    $self->UseTag('img');
	my ($w,$h) = $inst->dimensions;
	return '<img src="'.$self->WebPathFromFilename($inst->filename)
		."\" width=\"$w\" height = \"$h\" alt=\""
			.(defined($alt) ? $alt : $inst->wikiname)
				.'">';
}


sub GetWikiWikinames()
{
	my ($self) = @_;
	opendir IN_DIR, $self->sourcedir
		|| die "Unable to open directory ".$self->sourcedir." for reading\n";
	my %names;
	map {$names{$1} = 1 if /^(.*)\.wiki$/}
		readdir IN_DIR;
	closedir IN_DIR;
	my @images = $self->db->load('Image');
	map {$names{'Image:'.$_->wikiname} = 1} @images;
	return sort { $a cmp $b }  keys %names;
}

sub ResetTagsUsed()
{
	my ($self) = @_;
    $self->tagsused({});
}

sub UseTag()
{
	my ($self,$tag) = @_;
    $self->tagsused()->{$tag} //= 0;
    $self->tagsused()->{$tag}++;
}

sub IsTagUsed()
{
	my ($self,$tag) = @_;
    return $self->tagsused()->{$tag};
}


no Moose;
__PACKAGE__->meta->make_immutable;



