package FbyParse;
use Modern::Perl;
use utf8::all;

sub LoadOrCreateWikiEntry($$)
{
	my ($db, $wikiname) = @_;
	$wikiname =~ s/\s+/\ /xsg;
	$wikiname =~ s/\:\s*/\:/xsg;
	return $db->load_or_create('WikiEntry', wikiname=> $wikiname);
}


sub LoadOneWikiEntry($$)
{
	my ($db, $wikiname) = @_;
	$wikiname =~ s/\s+/\ /xsg;
	$wikiname =~ s/\:\s*/\:/xsg;
	my $entry = $db->load_one('WikiEntry', wikiname=> $wikiname);
#	print "Can't find entry for $wikiname\n" unless $entry;
	return $entry;
}


sub ConvertTextToWiki($@)
{
	my ($t,$isfile) = @_;
	
	$t =~ s/\:\s+/\:/xsg;
	$t =~ s/\s+/_/xsg;
	$t = Flutterby::Util::escape($t) unless $isfile;
	return $t;
}

sub OutputNameToLinkName($)
{
	my ($n) = @_;
	$n =~ s/\.html$//;
	return $n;
}


sub TagWiki()
{
	my ($fpi, $ref, $text) = @_;
	my $r;
	my $db = $fpi->db;

	$ref =~ s/\s+/ /xsg;
	$ref =~ s/\:\s+/\:/xsg;
	$text = $ref unless defined($text);

	die "$ref $text $fpi\n".CallStack() unless defined($ref);
	my $wikilink = ConvertTextToWiki($ref);

#	if ($ref =~ /^Category:/)
#	{
#		$fpi->categories->{$ref} = 1;
#	}

	if ($ref =~ /^Image:(.*)$/i) {
		my $imgname = $1;
		my $img = $fpi->db->load_one('Image', wikiname => $imgname);
		my @imginst;
		my $desc = '';
		my $align = '';
		my $divclass = 'image';
		my $width = '';

		my @notes = split /\|/, $text;
		
		foreach (@notes) {
			if ($_ eq 'thumb' && defined($img)) {
				push @imginst, ($img->thumb($db));
			}
			elsif ($_ eq 'full' && defined($img))
			{
				push @imginst, ($img->fullsize($db));
			} elsif ($_ eq 'left' || $_ eq 'right') {
				$align = $_;
			} elsif ($_ eq 'frame')
			{
				$divclass = 'imageframed';
			} elsif ($_ eq 'none')
			{
			} else {
				$desc .= $_;
			}
		}

		my ($w,$h);

		if ($#imginst < 0)
		{
			@imginst = defined($img) ? ($img->fullsize($db)) : (undef);
		}

		foreach my $imginst (@imginst)
		{
			my $caption = $desc;

			if (defined($imginst))
			{
				if ($imginst->needsDimensionsLoaded)
				{
					$imginst->loadDimensions();
					$db->write($imginst);
				}
				($w,$h) = $imginst->dimensions;
				$width = "style=\"width: $w"."px;\"";
				$caption .= " ($w by $h )" if ($#imginst > 0);
			}
			
			unless (defined($img))
			{
				$divclass = 'imagemissing';
				print STDERR "Missing $imgname from database\n";
			}

			$r = "<div class=\"$divclass$align\" $width>";
			
#			my $wikientry = LoadOneWikiEntry($fpi->db, $ref);
			my $wikientry = LoadOrCreateWikiEntry($fpi->db, $ref);
			my $wikiref = $db->load_one('WikiEntryReference',
										from_id => $fpi->wikiobj->id,
										to_id => $wikientry->id);
			unless ($wikiref)
			{
				$wikiref = $db->load_or_create('WikiEntryReference',
											   from_id => $fpi->wikiobj->id,
											   to_id => $wikientry->id);
				$wikientry->needsExternalRebuild(1);
				$db->write($wikientry);
			}

			$r .= "<a href=\"./$ref\">"
				if (defined($wikientry));
			$r .= $fpi->ImageTagFromInstance($imginst)
				if defined($imginst);
			$r .= "</a>"
				if (defined($wikientry));
			if (defined($img))
			{
				my $zoominst = $img->lightboxzoom($db);
				if (defined($zoominst))
				{
					$r .= join
						('',
						 '<a href="',
						 $fpi->WebPathFromFilename($zoominst->filename),
						 '" rel="lightbox" caption="',$caption, '">',
						 '<div class="imagezoombox">&nbsp;</div>',
						 '</a>',
						 "\n",
						);
				}
			}
			$r .= "<div class=\"imagecaption\"><p class=\"imagecaption\">$caption</p></div>" if $caption ne '';
			$r .= "</div>";
		}
	}
	elsif (my $wikientry = LoadOneWikiEntry($fpi->db, $ref))
	{
		$r = '<a href="./'.OutputNameToLinkName($wikientry->outputname).'">'
			.HTML::Entities::encode($text)
				.'</a>';
		print $fpi->wikiobj->wikiname." references ".$wikientry->wikiname."\n"
			if ($fpi->wikiobj->wikiname eq 'MFS');
		my $wer = $db->load_or_create('WikiEntryReference',
									  from_id => $fpi->wikiobj->id,
									  to_id => $wikientry->id);
		print "  ".$wer->from_id." to ".$wer->to_id." with object ".$wer->id."\n"
			if ($fpi->wikiobj->wikiname eq 'MFS');
	} else {
		$r = '<i>'
			.HTML::Entities::encode($text)
				.'</i>';
		$fpi->wikiobj->_missingReferences->{$ref} = 1;
	}

	#	$text =~
	#									.HTML::Entities::encode($text).
	#									'"><img border="0" src="/adbanners/lookingglass.png" alt="[Wiki]" width="12" height="12"></a>');
	#
	#	print "Wiki: $arg, $ref, $text\n";
	return $r;
}


sub TagDPL
{
	my ($fpi, $tag, $attrs, $data) = @_;
	my $text = '';
	my $db = $fpi->db;
	
	my @objs;
	
	if (defined($attrs->{category}))
	{
		my $linkstoname = "Category:$attrs->{category}";
		my $wikiobj = LoadOneWikiEntry($fpi->db, $linkstoname);
		
		if (defined($wikiobj))
		{
			@objs = map {$db->load_one('WikiEntry', id => $_->from_id) }
				$db->load('WikiEntryReference', to_id => $wikiobj->id);
		}
		else
		{
			warn "$linkstoname not found\n";
		}
	}
	else
	{
		@objs = $db->load('WikiEntry');
	}
	
	if (defined($attrs->{pattern}))
	{
		my $pattern = $attrs->{pattern};
		@objs = grep {defined($_) && $_->wikiname =~ /$pattern/} @objs;
	}
	
	
	if (defined($attrs->{order}) && $attrs->{order} eq 'descending')
	{
		@objs = sort {$b->wikiname cmp $a->wikiname} @objs;
	}
	else
	{
		@objs = sort {$a->wikiname cmp $b->wikiname} @objs;
	}
	
	if (@objs)
	{
		my $limit = defined($attrs->{count}) ? $attrs->{count} : 999999999;
		$text = '<ul>';
	
		for (my $i = 0; $i < @objs && $i < $limit; ++$i) {
			$text .= "<li><a href=\"./".ConvertTextToWiki($objs[$i]->wikiname).'">'
				.$objs[$i]->wikiname."</a>\n";
		}
		$text .= '</ul>';
	
	}
return $text;
}

sub TagVideoflash()
{
	my ($fpi, $tag, $attrs, $data) = @_;

	if (0)
	{
		return <<EOF;
<object style="" width="425" height="350"> <param name="movie" value="http://www.youtube.com/v/$data"> <param name="allowfullscreen" value="true"> <param name="wmode" value="transparent"> <embed src="http://www.youtube.com/v/$data" type="application/x-shockwave-flash" wmode="transparent" allowfullscreen="true" style="" flashvars="" width="425" height="350"></object>
EOF
	}
	else
	{
		return <<EOF;
<iframe width="420" height="315" src="http://www.youtube.com/embed/$data?rel=0" frameborder="0" allowfullscreen></iframe>
EOF
	}
}



sub TagGooglemap()
{
	my ($fpi, $tag, $attrs, $data) = @_;
    $fpi->UseTag('googlemap');

	
	my $r = '';

	$fpi->googlemapnum(0) unless ($fpi->googlemapnum);

	my $mapnum = $fpi->googlemapnum;
	$fpi->googlemapnum(++$mapnum);
	
	my $width = $attrs->{width} || 640;
	my $height = $attrs->{height} || 400;
	$width = $width . 'px';
	$height = $height . 'px';

	$r .= <<EOF;
<div class="map" id="map$mapnum" style="width: $width; height: $height; direction: ltr;"></div><script type="text/javascript">
//<![CDATA[
function makeMap$mapnum() 
{
    if (!GBrowserIsCompatible())
    {
        document.getElementById("map$mapnum").innerHTML = "In order to see the map that would go in this space, you will need to use a compatible web browser. <a href=\\"http://local.google.com/support/bin/answer.py?answer=16532&amp;topic=1499\\">Click here to see a list of compatible browsers.</a>";
        return;
    }
    var map = new GMap2(document.getElementById("map$mapnum"));
    map.addMapType(G_PHYSICAL_MAP);
    GME_DEFAULT_ICON = G_DEFAULT_ICON;
    map.setCenter(new GLatLng($attrs->{lat}, $attrs->{lon}), $attrs->{zoom}, G_HYBRID_MAP);
    GEvent.addListener(map, 'click', function(overlay, point)
		 {
           if (overlay)
		     {
               if (overlay.tabs)
               {
                   overlay.openInfoWindowTabsHtml(overlay.tabs);
               }
               else if (overlay.caption)
               {
                   overlay.openInfoWindowHtml(overlay.caption);
               }
           }
       });
    map.addControl(new GHierarchicalMapTypeControl());
    map.addControl(new GSmallMapControl());
EOF

	$data = '' unless defined($data);
	$data =~ s/^\s+//xsi;
	while ($data ne '') {
		$data =~ s/^\n+//xi;

		my $changed;
		#		if ($data =~ s/^(-?\d+\.\d+)\,\s*(-?\d+\.\d+)((\n([A-Z].*?))|(\,\s*(.*?))|)\n//xi)
		if ($data =~ s/^(kml|georss)\:(.*)(\n|$)//x)
		{
			$r .= "\nvar gx = new GGeoXml(\"$2\");\nmap.addOverlay(gx);\n";
			$changed = 1;
		}
		if ($data =~ s/^(-?\d+\.\d+)\,\s*(-?\d+\.\d+)(\,\s*(.*?))\n//xi)
		{
			my $lat = $1;
			my $lon = $2;
			my $caption = '';
			my $title = '';
			if (defined($3))
			{
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

			$r .= <<EOF;
	marker = new GMarker(new GLatLng($lat,$lon), {  'title' : '$title', 'icon': GME_DEFAULT_ICON,  'clickable': true  });
    marker.caption = '$caption';
    map.addOverlay(marker); GME_DEFAULT_ICON = G_DEFAULT_ICON;
EOF
			$changed = 1;
		}
		if ($data =~ s/^(-?\d+\.\d+)\,\s*(-?\d+\.\d+)\n([\w].*?)(\n+|$)//xi)
		{
			my $lat = $1;
			my $lon = $2;
			my $caption = '';
			my $title = '';
			if (defined($3))
			{
				$title = $3;
				$caption = "<p><b>$3</b></p>";
			}

			while ($data =~ s/^([A-Z].*?)\n//xi) {
				$caption .= $1;
			}

			$caption =~ s/\n/\\n/xsi;
			$caption =~ s/\'/\\'/xsi;

			$r .= <<EOF;
	marker = new GMarker(new GLatLng($lat,$lon), {  'title' : '$title', 'icon': GME_DEFAULT_ICON,  'clickable': true });
    marker.caption = '$caption';
    map.addOverlay(marker); GME_DEFAULT_ICON = G_DEFAULT_ICON;
EOF
			$changed = 1;
		}
		if ($data =~ s/^(\d+)\#([0-9A-F][0-9A-F])([0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F])\n//xi) {
			my $zoomq = $1;
			my $huh = $2;
			my $color = $3;
			$r .= 'map.addOverlay(new GPolyline( [ ';
			my $addComma;
			while ($data =~ s/^\n*(-?\d+\.\d+)\,\s*(-?\d+\.\d+)\n//x) {
				$r .= ($addComma ? ',' : '') . "new GLatLng($1,$2)";
				$addComma = 1;
			}
			$r .=  "], '#$color', $zoomq, 0.698039215686, {'clickable': false}));\n  GME_DEFAULT_ICON = G_DEFAULT_ICON;";
			$changed = 1;
		}
		if ($data =~ s/^\n*(-?\d+\.\d+)\,\s*(-?\d+\.\d+)\n//x)
		{
			$r .= 'map.addOverlay(new GPolyline( [ ';
			my $addComma;
			do
			{
				$r .= ($addComma ? ',' : '') . "new GLatLng($1,$2)";
				$addComma = 1;
			}
			while ($data =~ s/^\n*(-?\d+\.\d+)\,\s*(-?\d+\.\d+)\n//x);
			$r .=  "], '#758BC5', 6, 0.698039215686, {'clickable': false}));  GME_DEFAULT_ICON = G_DEFAULT_ICON;";
			$changed = 1;
		}
		if (!$changed) {
			print("Failed: $data\nFile: ".$fpi->wikiobj->inputname."\n");
			$data = '';
		}
	}
	$r .= <<EOF;
}
 addLoadEvent(makeMap$mapnum);
//]]>
</script>
EOF

	return $r;
}

sub LoadFileText($$)
{
	my ($fpi, $file) = @_;
	my $db = $fpi->db;
	if ($file =~ /\/Image\:(.*)\.wiki$/)
	{
		my $imagename = $1;
		my $img = $db->load_one('Image', 
								wikiname=> $imagename);
		if (defined($img))
		{
			my $t = '';
			my @desc;
				
			my $full = $img->fullsize($db);
			my $thumb = $img->thumb($db);
			unless (defined($full))
			{
				my @instances = $img->_sortinstances($db);
				foreach (@instances)
				{
					print join(" ", $_, $_->wikiname, @{$_->dimensions})."\n";
				}
			}
			else
			{
				$thumb = undef if ($thumb->filename eq $full->filename);

				if (defined($full))
				{
					my $cmd = 'jhead "'.$full->filename.'"';
					@desc = `$cmd`;
					shift @desc;
				}
				$t .= "== Full Size ==\n\n"
					.$fpi->ImageTagFromInstance($full)
						."\n\n"
							if (defined($full));

				if (open(I, $file))
				{
					$t .= join('',<I>);
					close I;
				}

				$t .= "== Thumbnail ==\n\n"
					.$fpi->ImageTagFromInstance($thumb)
						."\n\n"
							if (defined($thumb));
			
				$t .= join('<br>', grep {!(/^File date\s*\:/)} @desc)
					if (@desc);
			
				$t .= "\n\nAll sizes: "
					.join('|',
						  map {
							  '<a href="'.$fpi->WebPathFromFilename($_->filename)
								  .'">'.$_->width.'x'.$_->height.'</a>'
							  } $img->instances($db))
						."\n";
				return $t;
			}
		}
        else
        {
            warn "Unable to load object for $imagename\n";
        }
	}
	elsif (open(I, $file))
	{
		my $t = join('',<I>);
		close I;
		return $t;
	}
	return undef;
}


1;
