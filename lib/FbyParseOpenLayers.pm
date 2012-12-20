#!/usr/bin/perl
use Modern::Perl;
use utf8::all;

package FbyParse;

use Flutterby::Util;
use File::ShareDir ':ALL';
use Carp;

sub LoadSegmentedFile($)
{
	my ($file) = @_;
	my $filename = module_file('Fby', $file);
	my $sections = {};
	my $section = '';

	if (open(my $fh, $filename))
	{
		while (<$fh>)
		{
			if (/^\s*\/\/\s*FbySection:\s*(.*)$/)
			{
				$section = $1;
			}
			else
			{
				$sections->{$section} .= $_;
			}
		}
		close $fh;
	}
	else
	{
		carp("Unable to open $filename for reading");
	}
	while (my ($k,$v) = each %$sections)
	{
	}
	return $sections;
}

sub TagOpenLayers()
{
	my ($fpi, $tag, $attrs, $data) = @_;
    $fpi->UseTag('openlayers');

	my $sections = LoadSegmentedFile('openlayerstemplate.js');
	my $r;
	# <script src="http://maps.google.com/maps?file=api&amp;v=3&amp;key=ABQIAAAA5bnmoyI0qgIhAMohxYIDGRRnstFjj-VwPFW1Yamy-XfT3YF74RTtTIkyyd_WArVu_AjLpZ6ovlzZPw&amp;hl=en" type="text/javascript"></script>

	unless ($fpi->googlemapnum) {
		$fpi->googlemapnum(0);
	}
	my $mapnum = $fpi->googlemapnum;
	$fpi->googlemapnum(++$mapnum);
	
	my $width = $attrs->{width} || 640;
	my $height = $attrs->{height} || 400;
	$width = $width . 'px';
	$height = $height . 'px';
	my $markerlayer;

	$r .= <<EOF;
<div class="map" id="map$mapnum" style="width: $width; height: $height; direction: ltr;"></div><script type="text/javascript">
//<![CDATA[
EOF
	my %vars =
		(
		 mapnum => $mapnum,
		 lon => $attrs->{lon},
		 lat => $attrs->{lat},
		 zoom => $attrs->{zoom},

		);
	$r .= Flutterby::Util::subst($sections->{preamble}, \%vars);

	$data = '' unless defined($data);
	$data =~ s/^\s+//xsi;
	while ($data ne '') {
		$data =~ s/^\n+//xi;

		my $changed;
		#		if ($data =~ s/^(-?\d+\.\d+)\,\s*(-?\d+\.\d+)((\n([A-Z].*?))|(\,\s*(.*?))|)\n//xi)
		if ($data =~ s/^(kml)\:(.*)(\n|$)//x) {
			my %lvars = %vars;
			$lvars{kmlurl} = $2;
			$r .= Flutterby::Util::subst($sections->{KML}, \%lvars);
			$changed = 1;
		} elsif ($data =~ s/^(gpstrack):(.*?)\/(.*?)\/(.*?)(\/\n|$)//x) {
            print "GPS Track $2 $3 $4\n";
			my %lvars = (%vars, fromdate => $2, todate => $3, imgoffset => $4,
                        zoomlevel => ($attrs->{zoom} || 14));
			$r .= Flutterby::Util::subst($sections->{gpstracklayer}, \%lvars);
			$changed = 1;
        } elsif ($data =~ s/^(.*\.kml)(\n|$)//ix) {
			print "Got KML ref $1\n";
			my %lvars = %vars;
			$lvars{kmlurl} = $1;
			$r .= Flutterby::Util::subst($sections->{KML}, \%lvars);
			$changed = 1;
		} elsif ($data =~ s/^(georss)\:(.*)(\/.*)(\n|$)//x) {
			my %lvars = %vars;
			$lvars{georsslayer} = $3;
			$lvars{georssurl} = "$2$3";
			$r .= Flutterby::Util::subst($sections->{GeoRSS}, \%lvars);
			$changed = 1;
		}
		if ($data =~ s/^(-?\d+\.\d+)\,\s*(-?\d+\.\d+)(\,\s*(.*?))\n//xi) {
			my $lat = $1;
			my $lon = $2;
			my $caption = '';
			my $title = '';
			if (defined($3)) {
				$title = $4;
				$caption = "<p><b>$4</b></p>";
			}

			while ($data =~ s/^([A-Z].*?)\n//xi) {
				$caption .= $1;
			}

			$caption =~ s/\n/\\n/xsi;
			$caption =~ s/\'/\\'/xsi;
			$title =~ s/\n/\\n/xsi;
			$title =~ s/\'/\\'/xsi;

			if (!defined($markerlayer)) {
				$markerlayer = 1;
				$r .= Flutterby::Util::subst($sections->{markerlayerbegin}, \%vars);
			}

			my %lvars = %vars;
			$lvars{caption} = $caption;
			$lvars{title} = $title;
			$lvars{lat} = $lat;
			$lvars{lon} = $lon;
			$r .= Flutterby::Util::subst($sections->{marker}, \%lvars);
			$changed = 1;
		}
		if ($data =~ s/^(-?\d+\.\d+)\,\s*(-?\d+\.\d+)\n([\w].*?)(\n+|$)//xi)
		{
			my $lat = $1;
			my $lon = $2;
			my $caption = '';
			my $title = '';
			if (defined($3)) {
				$title = $3;
				$caption = "<p><b>$3</b></p>";
			}
			
			while ($data =~ s/^([A-Z].*?)\n//xi) {
				$caption .= $1;
			}
			
			$caption =~ s/\n/\\n/xsi;
			$caption =~ s/\'/\\'/xsi;
			
			if (!defined($markerlayer)) {
				$markerlayer = 1;
				$r .= Flutterby::Util::subst($sections->{markerlayerbegin}, \%vars);
			}

			my %lvars = %vars;
			$lvars{caption} = $caption;
			$lvars{title} = $title;
			$lvars{lat} = $lat;
			$lvars{lon} = $lon;
			$r .= Flutterby::Util::subst($sections->{marker}, \%lvars);
			$changed = 1;
		}
		if ($data =~ s/^(\d+)\#([0-9A-F][0-9A-F])([0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F])\n//xi)
		{
			my $zoomq = $1;
			my $huh = $2;
			my $color = $3;
			my %lvars = %vars;
			$lvars{zoomq} = $zoomq;
			$lvars{huh} = $huh;
			$lvars{color} = $color;

			$r .= Flutterby::Util::subst($sections->{vectorlayerpreamble}, \%lvars);
			while ($data =~ s/^\n*(-?\d+\.\d+)\,\s*(-?\d+\.\d+)\n//x)
			{
				$lvars{lat} = $1;
				$lvars{lon} = $2;
				$r .= Flutterby::Util::subst($sections->{vectorlayerpoint}, \%lvars);
			}
			undef $lvars{lat};
			undef $lvars{lon};
			$r .= Flutterby::Util::subst($sections->{vectorlayerpost}, \%lvars);
			$changed = 1;
		}
		if ($data =~ s/^\n*(-?\d+\.\d+)\,\s*(-?\d+\.\d+)\n//x)
		{
			my $zoomq = $1;
			my $huh = $2;
			my $color = '#758BC5';
			my %lvars = %vars;
			$lvars{zoomq} = $zoomq;
			$lvars{huh} = $huh;
			$lvars{color} = $color;

			$r .= Flutterby::Util::subst($sections->{vectorlayerpreamble}, \%lvars);
			while ($data =~ s/^\n*(-?\d+\.\d+)\,\s*(-?\d+\.\d+)\n//x)
			{
				$lvars{lat} = $1;
				$lvars{lon} = $2;
				$r .= Flutterby::Util::subst($sections->{vectorlayerpoint}, \%lvars);
			}
			undef $lvars{lat};
			undef $lvars{lon};
			$r .= Flutterby::Util::subst($sections->{vectorlayerpost}, \%lvars);
			$changed = 1;
		}

		if (!$changed)
		{
			print("Failed: $data\nFile: ".$fpi->wikiobj->inputname."\n");
			$data = '';
		}
	}
	$r .= Flutterby::Util::subst($sections->{post}, \%vars);
	$r .= <<EOF;
//]]>
</script>
EOF

	return $r;
}


1;
