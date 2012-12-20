use Modern::Perl;
use utf8::all;

package Person;
use Moose;
has 'id' => (is => 'rw');
has 'email' => (is => 'rw', isa => 'Str');
has 'emailcookie' => (is => 'rw', isa => 'Str');
has 'magiccookie' => (is => 'rw', isa => 'Str');
has 'emailconfirmed' => (is => 'rw', isa => 'Int');
no Moose;
__PACKAGE__->meta->make_immutable;

package KML;
use Moose;
has 'id' => (is => 'rw');
has 'owner_id' => (is => 'rw', isa => 'Int');
has 'name' => (is => 'rw', isa => 'Str');
has 'lastupload' => (is => 'rw', isa => 'Num', default => 0);
has 'timezone' => (is => 'rw', isa => 'Num', default => 0);
has 'lat' => (is => 'rw', isa => 'Num', default => 0);
has 'lon' => (is => 'rw', isa => 'Num', default => 0);
has 'minlat' => (is => 'rw', isa => 'Num', default => 9999);
has 'minlon' => (is => 'rw', isa => 'Num', default => 9999);
has 'maxlat' => (is => 'rw', isa => 'Num', default => -9999);
has 'maxlon' => (is => 'rw', isa => 'Num', default => -9999);
has 'zoom' => (is => 'rw', isa => 'Num', default => 14);
has 'overridelon' => (is => 'rw', isa => 'Num', default => 9999);
has 'overridelat' => (is => 'rw', isa => 'Num', default => 9999);
no Moose;
__PACKAGE__->meta->make_immutable;

package Device;
use Moose;
has 'id' => (is => 'rw');
has 'user_id' => (is => 'rw', isa => 'Int');
has 'name' => (is => 'rw', isa => 'Str');
no Moose;
__PACKAGE__->meta->make_immutable;



package LocationSample;
use Moose;
has 'id' => (is => 'rw');
has 'device_id' => (is => 'rw', isa => 'Int');
has 'sampletime' => (is => 'rw', isa => 'ISO8601Timestamp');
has 'lat' => (is => 'rw', isa => 'Num');
has 'lon' => (is => 'rw', isa => 'Num');
has 'alt' => (is => 'rw', isa => 'Num');
has 'speed' => (is => 'rw', isa => 'Num');
has 'heading' => (is => 'rw', isa => 'Num');
no Moose;
__PACKAGE__->meta->make_immutable;

1;
