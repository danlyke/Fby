#!/usr/bin/perl -w
use Modern::Perl;
use utf8::all;
use Moose::Util::TypeConstraints;

type 'ISO8601Timestamp' => where { defined $_ && $_ =~ /^\d\d\d\d-\d\d-\d\d[T ]\d\d:\d\d:\d\dZ?/ };

type 'WGS84Point' => where { defined($_) && (ref($_) eq 'ARRAY') && ($#$_ == 1) };
type 'WGS84Polygon' => where { defined $_ && ref($_) eq 'ARRAY' && $#$_ > 1 };


package FbyDB::Statement;
use Moose;

has 'sth' => (is => 'ro');
has 'db' => (is => 'ro');
has 'class' => (is => 'ro');
has 'attrs' => (is => 'ro');

sub fetchrow()
{
	my $self = shift;

	if (my $row = $self->sth->fetchrow_hashref)
	{
		my %args;
		while (my ($k,$v) = each %$row)
		{
			$args{$k} = $self->db->_setsqlvalue($self->attrs, $k, $v)
				if (defined($v));
		}
		return $self->class->new(%args);
	}
	return undef;
}


no Moose;
__PACKAGE__->meta->make_immutable;

package FbyDB::Connection;
use Moose;
has 'dbh' => (is => 'rw');
has 'connectargs' => (is => 'rw');
has 'debug' => (is => 'rw');
use DBI;


use Carp;
sub CallStack
{
    local $@;
    eval { confess( '' ) };
    my @stack = split m/\n/, $@;
    shift @stack for 1..3; # Cover our tracks.
    return wantarray ? @stack : join "\n", @stack;
}



sub connect(@)
{
	my $self = shift;
	my $dbh = DBI->connect(@_)
		|| die $DBI::errstr."\n".CallStack;
	$self->connectargs(\@_);
	$self->dbh($dbh);
}




my %typemappings = 
(
 'Str' => 'TEXT',
 'Int' => 'INTEGER',
 'Num' => 'FLOAT',
 'ISO8601Timestamp' => 'TIMESTAMP',
 'WGS84Point' => 'geography(POINT,4326)',
 'WGS84Polygon' => 'geography(POLYGON,4326)',
);


sub tablename($)
{
	my ($self,$type) = @_;
	$type = ref($type) || $type;
	$type =~ s/^.*\:\://;
	return $type;
}


sub get_attrs($)
{
	my ($self,$type) = @_;
	$type = ref($type) || $type;
	my %attrs;
	foreach my $attr ($type->meta->get_all_attributes)
	{
		if (substr($attr->name,0,1) ne '_')
		{
			if (defined($attr->{type_constraint}))
			{
				$attrs{$attr->name} = $typemappings{$attr->{type_constraint}};
			}
			else
			{
				$attrs{$attr->name} = 'TEXT';
			}
		}
	}
	return \%attrs;
}


sub create_statements_indexes($)
{
	my ($self, $type) = @_;
	$type = ref($type) || $type;
	my @ret;
	my @unique_indexes;

	@unique_indexes = eval {$type->unique_indexes};

	foreach (@unique_indexes)
	{
		my @types = ref($_) eq 'ARRAY' ? @$_ : ($_);

		push @ret, 'CREATE UNIQUE INDEX '
			.join('_', $type, @types)
			." ON $type("
			.join(',', @types)
			.')';
	}
	return @ret;
}

sub create_statement($)
{
	my ($self, $type) = @_;

	my $attrs = $self->get_attrs($type);

	my $r = 'CREATE TABLE '.$self->tablename($type)
		." ( id "
		.join(",\n",
			  (($self->connectargs()->[0] =~ /^DBI:Pg:/)
			   ? 'SERIAL PRIMARY KEY' : 'INTEGER PRIMARY KEY AUTOINCREMENT'),
			  (map {"  $_ $attrs->{$_}"} grep { !($_ eq 'id') } keys %$attrs))
		."\n);\n";
	return $r;
}

sub do($@)
{
	my $self = shift;

	$self->dbh()->do(@_)
			|| die $self->dbh()->errstr."\n@_\n"."\n".CallStack;
}

sub do_anyway($@)
{
	my $self = shift;

	$self->dbh()->do(@_)
			|| warn $self->dbh()->errstr."\n@_\n"."\n".CallStack;
}

sub quote($)
{
	my $self = shift; 
	return $self->dbh()->quote(@_);
}

my %sqlgetmappings =
(
 'geography(POINT,4326)' => sub
 {
	 return sprintf("ST_GeographyFromText('SRID=4326;POINT(%f %f %f)')", @{$_[0]})
		 if (@{$_[0]} > 2);
	 return sprintf("ST_GeographyFromText('SRID=4326;POINT(%f %f)')", @{$_[0]});
 },
 'geography(POLYGON,4326)' => sub
 {
	 my $ps = shift;
	 return "ST_GeographyFromText('SRID=4326;POLYGON(("
		 .join(',', map {sprintf('%f %f %f', @$_); } @$ps)
			 ."))')"
				 if (@{$ps->[0]} > 2);
	 return "ST_GeographyFromText('SRID=4326;POLYGON(("
		 .join(',', map {sprintf('%f %f', @$_); } @$ps)
			 ."))')";
 },
);

my %sqlsetmappings =
(
 'geography(POINT,4326)' => sub
 {
	 return undef unless defined($_[0]);
	 return undef unless $_[0] =~ /POINT\((\-?\d+(\.\d+)?)\s+(\-?\d+(\.\d+)?)\)/si;
	 return [$1,$3];
 },
 'geography(POLYGON,4326)' => sub
 {
	 return undef unless defined($_[0]);
	 return undef unless $_[0] =~ /POLYGON\(\((.*?)\)\)/si;
	 my @a = split /\s*\,\s*/si, $1;
	 @a = map {[split /\s+/si, $_]} @a;
	 return \@a;
 },
);


sub _getsqlvalue($$$$)
{
	my ($self, $obj, $attrs, $key) = @_;
	if (defined($attrs->{$key}))
	{
		my $type = $attrs->{$key};
		my $mapping = $sqlgetmappings{$type};
		return  &$mapping($obj->$key)
			if (defined($mapping));
	}
	return $self->dbh()->quote($obj->$key);
}

sub _setsqlvalue($$$$)
{
	my ($self, $attrs, $key, $value) = @_;
	if (defined($attrs->{$key}))
	{
		my $type = $attrs->{$key};
		my $mapping = $sqlsetmappings{$type};
		return &$mapping($value)
			if (defined($mapping));
	}
	return $value;
}

sub get_update_sql($$@)
{
	my ($self, $obj, $attrs) = @_;
	$attrs ||= $self->get_attrs($obj);
	my $sql = 'UPDATE '.$self->tablename($obj)
		.' SET '
			.join(', ', 
				  map
				  {
					  "$_=".$self->_getsqlvalue($obj, $attrs, $_)
				  } keys %$attrs )
				.' WHERE id='.$self->dbh()->quote($obj->id);
	return $sql;
}


sub get_insert_sql($$@)
{
	my ($self, $obj, $attrs) = @_;
	$attrs ||= $self->get_attrs($obj);
		my @keys = grep { defined($obj->$_) } keys %$attrs;

	my $sql = 'INSERT INTO '.$self->tablename($obj)
		.'('.join(', ', @keys).') VALUES ('
			.join(', ', map { $self->_getsqlvalue($obj, $attrs, $_) } @keys )
				.')';
	return $sql;
}


sub write($$@)
{
	my ($self,$obj, $anyway) = @_;
	my $attrs = $self->get_attrs($obj);

	if (defined($obj->id))
	{
		my $sql = $self->get_update_sql($obj, $attrs);
		print "$sql\n"
			if ($self->debug);
		$self->do($sql);
	}
	else
	{
		my $sql = $self->get_insert_sql($obj, $attrs);
		print "$sql\n"
			if ($self->debug);

		$anyway ? $self->do_anyway($sql) : $self->do($sql);
		if ($self->connectargs()->[0] =~ /^DBI:Pg:/)
		{
			my @a = $self->dbh()->selectrow_array("SELECT CURRVAL(pg_get_serial_sequence('"
												  .$self->tablename($obj)
												  ."', 'id'))");
			$obj->id($a[0]);
		}
		else
		{
			my $lastrowid = $self->dbh()->last_insert_id(undef,undef,$self->tablename($obj),'id');

			die "Failed to get row id!\n".CallStack() if (!defined($lastrowid));
			$obj->id($lastrowid);
		}
	}
}

my %typenamemappings =
(
 'geography(POINT,4326)' => 'st_astext(%s)',
 'geography(POLYGON,4326)' => 'st_astext(%s)',
);

sub select_vals_from_attrs($$)
{
	my $self = shift;
	my $attrs = shift;

	my @vals;

	while (my($k,$v) = each %$attrs)
	{
		my $tnm = $typenamemappings{$v};
		$k = sprintf("$typenamemappings{$v} AS $k", $k)
			if (defined($tnm));
		push @vals, $k;
	}
	return @vals;
}

sub prepare($$@)
{
	my $self = shift;
	my $class = shift;
	my $keys;
	my $conditions = '';

	if ($#_ == 0)
	{
		$conditions = shift;
		$conditions = "WHERE $conditions"
			unless (!defined($conditions) ||
					$conditions =~ /^\s*(WHERE|ORDER\s+BY)\s*.+/);
	}
	else
	{
		$keys = @_ ? ((ref($_[0]) eq 'HASH') ? \%{$_[0]} : {@_}) : undef;
	}

	my $attrs = $self->get_attrs($class);

	my @attrs = $self->select_vals_from_attrs($attrs);

	my $sql = 'SELECT '.join(', ', @attrs).' FROM '.$self->tablename($class)
		.(defined($keys) ? ' WHERE '.join(' AND ', map { "$_=".$self->dbh()->quote($keys->{$_}) } keys %$keys) : " $conditions");
	print "$sql\n"
		if ($self->debug);
	my $sth = $self->dbh()->prepare($sql)
		|| die $self->dbh()->errstr."\n$sql\n"."\n".CallStack;
	$sth->execute()
		|| die $self->dbh()->errstr."\n$sql\n"."\n".CallStack;

	my $st = FbyDB::Statement->new(sth => $sth, db => $self, class => $class, attrs => $attrs);
	return $st;
}

sub load($$@)
{
	my $self = shift;
	my $class = shift;
	my $st = $self->prepare($class, @_);

	my @objs;

	while (my $obj = $st->fetchrow())
	{
		push @objs, $obj;
	}

	if ($#objs == 0 && !wantarray)
	{
		return $objs[0];
	}
	return @objs;
}


sub delete($$@)
{
	my $self = shift;
	my $class = shift;
	my $keys = @_ ? ((ref($_[0]) eq 'HASH') ? \%{$_[0]} : {@_}) : undef;

	my $attrs = $self->get_attrs($class);
	my @attrs = keys %$attrs;

	my $sql = 'DELETE FROM '.$self->tablename($class)
		.' WHERE '.join(' AND ', map { "$_=".$self->dbh()->quote($keys->{$_}) } keys %$keys);
	$self->do($sql);
}

sub load_one($$@)
{
	my ($self, $class, @keys) = @_;
	my @ret = $self->load($class,@keys);
	die "Too many results for load of class $class ("
		.join(', ' , @keys).")\n"."\n".CallStack
		unless @ret < 2;

	return (scalar(@ret) == 1) ? $ret[0] : undef;
}


sub load_or_create($$@)
{
	my ($self, $type, %args) = @_;

	my $obj = $self->load_one($type, %args );

	unless ($obj)
	{
		$obj = $type->new(%args);
		$self->write($obj);
	}

	return $obj;
}


no Moose;
__PACKAGE__->meta->make_immutable;

1;

__END__


=head1 NAME

FbyDB - Simple SQL database helper for Moose

=head1 SYNOPSIS

Create a C<Moose> object with an 'id' member:

    package Person;
    use Moose;
    has 'id' => (is => 'rw', isa => 'Int');
    has 'name' => (is => 'rw', isa => 'Str');
    no Moose;
    __PACKAGE__->meta->make_immutable;

set up a connection:

    use FbyDB;
    my $db = FbyDB::Connection->new(debug=>1);
    $db->connect("dbi:SQLite:dbname=./db.sqlite3");

You can get SQL to create tables from a Moose class by doing something like:

    $db->do($db->create_statement('Person')

Load or create objects with:

    my $person = $db->load_or_create('Person', name => 'Dan');

or, of course, just use

    Person->new(name=>'Dan')

if you know don't want an initial query. Also available is 

	my $person = $db->load_one('Person', name=>'Dan');
    my @people = $db->load('Person', name=>'Dan');
    $db->delete('Person', name=>'Dan');

Write objects with

    $db->write($person);

If the 'id' member is defined, this does an UPDATE, otherwise it does
an INSERT.

=head1 DESCRIPTION

I wanted something that let me write Moose OO Perl but still let me
use an SQL database later for what it's good for. This is that
hack. KiokuDB was too complex for a simple key value database that I
couldn't query from straight SQL, nothing else seemed to be there.



