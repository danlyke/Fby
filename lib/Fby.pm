use Modern::Perl;
use utf8::all;

use FbyDB;

use FbyObjects;
use FbyParserInfo;

package Fby;

use List::Util qw(min);
use Carp;
$Carp::Verbose = 1;

sub CallStack
{
    local $@;
    eval { confess( '' ) };
    my @stack = split m/\n/, $@;
    shift @stack for 1..3;      # Cover our tracks.
    return wantarray ? @stack : join "\n", @stack;
}

my $outputdir;                  # = '/var/www';
my $googlemapsapikey;

use File::Find;

my %images;
my $fbyimagesdb;

sub FoundImage()
{
	if ($File::Find::name =~ /^(.*\/)(.*\.(jpg|png))$/i
		&& -f $File::Find::name) {
		
		my $inst = $fbyimagesdb->load_or_create('ImageInstance', filename => $File::Find::name);
		if ($inst->needsDimensionsLoaded) {
			$inst->loadDimensions();
			$fbyimagesdb->write($inst);
		}

		my $imagename = $inst->wikiname;

		my ($x, $y) = $inst->dimensions;
		my $image = $fbyimagesdb->load_or_create('Image', 
												 wikiname=> $imagename);

		if (defined($image->id)) {
			$images{$imagename} = $image;

			if (!defined($inst->image_id())
				|| $inst->image_id() ne $image->id) {
				$inst->image_id($image->id);
				$fbyimagesdb->write($inst);
			}
		} else {
			die "Insert into db failed for $imagename\n";
		}
	}
}



#sub WebPathFromFilename($)
#{
#	my ($path) = @_;
#	$path =~ s/^$outputdir//;
#	return $path;
#}
#
#
#sub ImageTagFromInstance($@)
#{
#	my ($inst, $alt) = @_;
#
#	my ($w,$h) = $inst->dimensions;
#	return '<img src="'.WebPathFromFilename($inst->filename)
#		."\" width=\"$w\" height = \"$h\" alt=\""
#			.(defined($alt) ? $alt : $inst->wikiname)
#				.'">';
#}

sub FindAllFiles($$$)
{
	my ($fpi, $sourcedir, $subdir) = @_;
	my $db = $fpi->db;
	my $outputdir = $fpi->outputdir;

	$fbyimagesdb = $db;

	my $path = "$outputdir/$subdir";
	$path = $1 if ($path =~ /^(.*)$/);
	find({ wanted=>\&FoundImage,
	       follow => 1 },
	     $path);

	$fpi->DebugPrint("Done with find\n");
}


my $imageinstances;

sub FoundUntrackedImage()
{
    if (!defined($imageinstances->{$File::Find::name})) {
        FoundImage()
    }
}

sub FindUntrackedImages($$$)
{
	my ($fpi, $sourcedir, $subdir) = @_;
	my $db = $fpi->db;
	my $outputdir = $fpi->outputdir;

	$fbyimagesdb = $db;

	my $path = "$outputdir/$subdir";
	$path = $1 if ($path =~ /^(.*)$/);
	find({ wanted=>\&FoundUntrackedImage,
	       follow => 1 },
	     $path);
}


use Flutterby::Parse::Text;
use Data::Dumper;
use Flutterby::Tree::Find;
use Flutterby::Output::HTML;
use Flutterby::Output::Text;
use XML::RSS;
use Email::Date::Format qw(email_date);
use Cwd;
use FbyParse;
use FbyParseOpenLayers;

my $stagingdir = getcwd.'/html_staging';
my $sourcedir = 'mvs';



my $dbfilename = 'var/fby.sqlite';
my $lastscanfilename = 'var/lastscan.txt';

my $existingdb = 1; -f $dbfilename;
my $db = FbyDB::Connection->new(
								#debug=>1
                               );
$db->connect(
			 'DBI:Pg:dbname=flutterbynet;host=localhost',
			 'danlyke', 'danlyke',

             #	"dbi:SQLite:dbname=$dbfilename",
             #	'bdb:dir=var/fby_bdb',
             #	create => 1,
            );

#undef $existingdb;

unless (defined($existingdb))
{
	foreach ('ImageInstance', 'Image', 'WikiEntry', 'WikiEntryReference') {
		my $sql = $db->create_statement($_);
		print "Doing $sql\n";
		$db->do($sql);
	}
	$db->do('CREATE INDEX ImageInstance_image_id ON ImageInstance(image_id)');
	$db->do('CREATE INDEX ImageInstance_filename ON ImageInstance(filename)');
	$db->do('create unique index wikientryname on wikientry(wikiname)');
	$db->do('create index to_id on wikientryreference(to_id)');
}



sub ReadConfig
{
    my %config;
	
    open(I, "/home/danlyke/.fby/config")
        || die "Unable to open $ENV{'HOME'}/.fby/config\n".CallStack;
    while (<I>) {
        $config{$1} = $2 if (/^(\w+)\s*\:\s*(.*$)/);
        $outputdir = $1 if (/^OutputDir:\s*(.*)$/);
        $googlemapsapikey = $1 if (/^GoogleMapsAPIKey:\s*(.*)$/);
        chdir $1 if (/^InstallDir\:\s*(.*)$/);
    }
    close I;
	return \%config;
}


sub InstantiateFPI()
{
	ReadConfig();
	my $fpi = FbyParserInfo->new(outputdir => $outputdir,
								 db => $db,
								 suffix => '.html',
								 sourcedir => $sourcedir,
								 stagingdir => $stagingdir);
	return $fpi;
}

sub SingleFile($$)
{
	my ($wikiobj, $fpi) = @_;
	my $file;
    if (defined($wikiobj->inputname)) {
		$file = $fpi->sourcedir.'/'.$wikiobj->inputname
    } else {
        for my $ext ('.wiki', '.html') {
            my $fn = $fpi->sourcedir.'/'.$wikiobj->wikiname.$ext;
            $file = $fn if (!defined($file) && -f $fn);
        }
    }

    unless ($file)
    {
        warn "Unable to find file for ".$wikiobj->wikiname." attempting creative load\n";
        $file = $fpi->sourcedir.'/'.$wikiobj->wikiname.'.wiki';
    }

    my $t = FbyParse::LoadFileText($fpi, $file);
    if (defined($t)) {
        $fpi->ResetTagsUsed();
        
        my $parse;
        
        if ($file =~ /\.html$/) {
            $parse = Flutterby::Parse::HTML->new(-allowalltags => 1);
        } else {
            # Remove comments
            $t =~ s/\<\!\-\-\s+(.*?)\s\-\-\>//xsig;

            $parse = Flutterby::Parse::Text->new(-wiki => \&FbyParse::TagWiki,
                                        -specialtags =>
                                        {
                                         'dpl' => \&FbyParse::TagDPL,
                                         'googlemap' => \&FbyParse::TagOpenLayers,
                                         'openlayers' => \&FbyParse::TagOpenLayers,
                                         'videoflash' => \&FbyParse::TagVideoflash,
                                        },
                                        -callbackobj => $fpi);
        }
        my $tree = $parse->parse($t);
        return $tree;
    }
    warn "Unable to open $file for reading";
    return undef;
}

sub numeric_part($@)
{
    my ($t,$label) = @_;
    $label //= '<unknown>';
    croak "No numeric part to item $label: '$t'"
        unless $t =~ /(\d+)/;
    return $1;
}


sub build_list_from_subsections
{
    my ($subsections) = @_;
    my $minlevel = min(map {numeric_part($_->[0], 'minimum header level')} @$subsections);
    my $curlevel = numeric_part($subsections->[0]->[0], 'first subsection') - $minlevel;


    my $sect = [{}];
    my $rootsect = $sect;

    for my $sub (@$subsections) {
        my $thislevel = numeric_part($sub->[0], 'subsection') - $minlevel;

        for (; $thislevel > $curlevel; $curlevel++) {
            my $newsect = [{}];
            push @$sect, 'ul', $newsect;
            $sect = $newsect;
        }

        if ($thislevel < $curlevel) {
            $sect = $rootsect;
            for ($curlevel = 0; $curlevel < $thislevel; ++$curlevel) {
                $sect = $sect->[$#$sect];
            }
        }
        push @$sect, 'li', [{},
                            'a', [ {href => '#'.$sub->[2]},
                                   '0', $sub->[1],
                                 ],
                            '0', "\n",
                           ];
    }
    $rootsect = ['ul', $rootsect ];

    return wantarray ? @$rootsect : $rootsect;
}

sub OutputTreeAsHTML($$$$$)
{
    my ($tree, $title, $fpi, $subsections, $linkshere) = @_;
    my $head = Flutterby::Tree::Find::node($tree, 'head');

    my $login_manager = '/cgi-bin/loginmgr.pl';
#    my $login_manager;
    my @onload;

    if (!defined($head))
    {
        my $html = Flutterby::Tree::Find::node($tree, 'html');
        $head = ['head', [{},]];
        $html = $html->[1];
        my $att = shift @$html;
        unshift @$html, $att, @$head;
    }

    {
        my @additionalheaders;
        if ($title eq 'User:DanLyke') {
            @additionalheaders =
                (
                 'link',
                 [ { rel  => "openid.server",
                     href => "http://www.myopenid.com/server" },
                   '0', "\n", ],
                 'link',
                 [ { rel  => "openid.delegate",
                     href => "http://danlyke.myopenid.com/" },
                   '0', "\n", ],
                 'link',
                 [ { rel  => "openid2.local_id",
                     href => "http://danlyke.myopenid.com" },
                   '0', "\n", ],
                 'link',
                 [ { rel  => "openid2.provider",
                     href => "http://www.myopenid.com/server" },
                   '0', "\n", ],
                 'meta',
                 [ { 'http-equiv' => "X-XRDS-Location",
                     content      => "http://www.myopenid.com/xrds?username=danlyke.myopenid.com" },
                   '0', "\n", ],
                 'link',
                 [ { rel => "meta",
                     type => "application/rdf+xml",
                     title => "FOAF",
                     href => "http://www.flutterby.net/User%3aDanLyke_foaf.rdf",
                   },
                   '0', "\n", ],
                 'link',
                 [ { rel => "alternate",
                     type => "text/directory",
                     href => "http://www.flutterby.net/User%3aDanLyke.vcard",
                   },
                   '0', "\n"
                 ],
                 '0', "\n",
                );
        }
        if ($title =~ /^Category:/) {
            my $syndifile = $title;
            $syndifile =~ s/\s/_/g;
            push @additionalheaders,
                (
                 'link',
                 [ { rel => 'alternate',
                     href => "http://www.flutterby.net/$syndifile.rss",
                     title => 'RSS',
                     type => 'application/rss+xml',
                   },
                   '0', "\n", ],
                );
        }

        my @cssjs;

        if ($fpi->IsTagUsed('openlayers')
            || $fpi->IsTagUsed('img')
            || $login_manager)
        {
            push @cssjs,
                (
                 'script' => [ { type => "text/javascript",
                                 src => "js/jquery-1.7.1.min.js",
                               },
                             ],
                );
        }
        if ($login_manager)
        {
            push @cssjs,
                (
                 'script' => [ { type => "text/javascript",
                                 src => "js/jquery.cookie.js",
                               },
                             ],
                );

            push @onload, "if (\$.cookie('magic')) { \$.get('$login_manager', { n:'$title' }, function(data,status,request) { \$('#login').html(data); }); }";

        }
        if ($fpi->IsTagUsed('img')) {
            push @cssjs,
                (
                 'script' => [ { type => "text/javascript",
                                 src => "js/jquery.lightbox-0.5.js",
                               },
                             ],
                 'link' => [ { rel => 'stylesheet',
                               href => "css/jquery.lightbox-0.5.css",
                               type => "text/css",
                               media => "screen",
                             }
                           ],

                 'script' => [ {
                                type => "text/javascript"
                               },
                               '0' => <<'EOF',
$(function() {
    // Use this example, or...
    $('a[rel|="lightbox"]').lightBox(); // Select all links that contains lightbox in the attribute rel
});
EOF
                             ], 
                );
        }
        if ($fpi->IsTagUsed('googlemap') || $fpi->IsTagUsed('openlayers')) {
            push @cssjs,
                (
                 'script' => [ { type => "text/javascript",
                                 src => "http://maps.google.com/maps/api/js?sensor=false&v=3.6&key=$googlemapsapikey",
                               },
                             ],
                );
        }
        if ($fpi->IsTagUsed('openlayers')) {
            push @cssjs,
                (
                 'script' => [ { type => "text/javascript",
                                 src => "js/fby/maputils.js",
                               },
                             ],
                );
        }
        if ($fpi->IsTagUsed('googlemap') || $fpi->IsTagUsed('openlayers')) {
            push @cssjs,
                (
                 'script' => [ {
                                type => "text/javascript"
                               },
                               '0' => <<'EOF',
//<![CDATA[
var mapIcons = {};function addLoadEvent(func) {var oldonload = window.onload;if (typeof oldonload == 'function') {window.onload= function() {oldonload();func();};} else {window.onload = func;}}
//]]>
EOF
                             ], 
                );
        }


        if ($fpi->IsTagUsed('openlayers')) {
            push @cssjs,
                (
                 'link' => [ { rel => 'stylesheet',
                               href => "js/ol/default/style.css",
                               type => "text/css",
                             }
                           ],
                 'link' => [ { rel => 'stylesheet',
                               href => "js/ol/default/google.css",
                               type => "text/css",
                             }
                           ],
                 'script' => [ { type => "text/javascript",
                                 src => "js/OpenLayers-2.11/OpenLayers.js",
                               },
                             ],
                 'script' => [ { type => "text/javascript",
                                 src => "js/OSM_LocalTileProxy.js",
                               },
                             ],

                 'script' => [ {
                                type => "text/javascript"
                               },
                               '0' => <<'EOF',
EOF
                             ], 
                );
        }


        if (@onload)
        {
            my $onload = join("\n", @onload);
            push @cssjs,
                (
                 'script' => [ { type => "text/javascript",
                               },
                               '0' => <<EOF,
//<![CDATA[
//<![CDATA[
\$(document).ready(function() {
$onload
});
//]]>
EOF
                             ],
                );

        }

        my @moreheaders;
        my $odd = 0;
        for (@additionalheaders, @cssjs) {
            push @moreheaders, '0', "\n" if (!($odd & 1));
            push @moreheaders, $_;
            ++$odd;
        }

        $head = ['head', [{},
                          'title' => [{},
                                      '0', $title
                                     ],
                          '0', "\n",
                          'style' => [ { type=> 'text/css' },
                                       '0', '@import "/screen.css";'
                                     ],
                          '0', "\n",
                          'link' => [ { rel  => 'icon',
                                        href => '/favicon.ico',
                                        type => 'image/ico',
                                      },
                                    ],
                          '0', "\n",
                          'link' => [ { rel  => 'shortcut icon',
                                        href => '/favicon.ico',
                                      },
                                    ],
                          '0', "\n",
                          @moreheaders,
                         ],
                 '0', "\n",
                ];
        my $html = Flutterby::Tree::Find::node($tree, 'html');
        my $existinghead = Flutterby::Tree::Find::node($tree, 'head');

        if ($existinghead) {
            my %header;
            while (my ($k,$v) = each %{$existinghead->[1]->[0]}) {
                $head->[1]->[0]->{$k} = $v;
            }
            for (my $i = 1; $i < $#{$head->[1]}; $i += 2) {
                if ($head->[1]->[$i] ne '0') {
                    my $r;
                    my $output = Flutterby::Output::HTML->new();
                    $output->setOutput(\$r);
                    $output->output([$head->[1]->[$i], $head->[1]->[$i+1]]);
                    $header{$r} = 1;
                }
            }
            my $originalheadercount = $#{$existinghead->[1]};
            for (my $i = 1; $i < $originalheadercount; $i += 2) {
                if ($existinghead->[1]->[$i] ne '0') {
                    my $r;
                    my $output = Flutterby::Output::HTML->new();
                    $output->setOutput(\$r);
                    $output->output([$existinghead->[1]->[$i], $existinghead->[1]->[$i+1]]);

                    push @{$existinghead->[1]}, $existinghead->[1]->[$i], $existinghead->[1]->[$i+1]
                        unless ($header{$r});
                }
            }
        }
        $html = $html->[1];
        my $att = shift @$html;
        unshift @$html, $att, @$head;
        #splice @$html, 1, 0, $head;
    }

	my $body = Flutterby::Tree::Find::node($tree, 'body');
	$body = $body->[1];

	my @contentsections;

    my @contentdiv = 
        (
         'div', [ {class=>'content'},splice(@$body, 1, $#$body) ],
        );

	if (@$subsections)
    {
        my @list = build_list_from_subsections($subsections);

        my $subbody = $contentdiv[1];
        my $i;

        for ($i = 1; $i < @$subbody && $subbody->[$i] !~ /^h\d$/ ; $i += 2)
        {
#            print "Subbody ref $i $subbody->[$i]\n";
        }

        if ($i == 1)
        {
            unshift @contentdiv,
                (
                 'div',
                 [ {class=>'sections'}, 
                   'h2', [{}, '0', 'Sections' ],
                   '0', "\n",
                   @list,
                   '0', "\n",
                 ],
                 );
        }
        elsif ($i < @$subbody)
        {
            my @rest = splice @$subbody, $i, scalar($subbody) - $i;
            push @contentdiv,
                (
                 'div',
                 [ {class=>'sections'}, 
                   'h2', [{}, '0', 'Sections' ],
                   '0', "\n",
                   @list,
                   '0', "\n",
                 ],
                 'div',
                 [ {class => 'content'}, @rest],

                );
        }
    }

	{
		push @contentsections,
            @contentdiv,
            'br', [{ clear => "all" }],
            'div',
                [
				 { class => 'footer' },
				 'p',
				 [
				  {},
				  '0', 'Flutterby.net is a publication of ',
				  'a', [
                        {href=>'mailto:danlyke@flutterby.com'},
                        '0', 'Dan Lyke',
                       ],
				  '0', ' and unless otherwise noted, copyright by Dan Lyke',
				 ]
                ];
		}
	



	push @$body, 'div',
	[
	 {
		 class => 'contentcolumn',
	 },
	 @contentsections,
	  
	];

	my @sidebar;

	if (@$linkshere)
	{
		my @linksherediv = {};
		foreach (@$linkshere)
		{
			push @linksherediv,
				'li', [ {}, 'a', [ { href => './'.
									 FbyParse::ConvertTextToWiki($_->wikiname)},
								   '0',
								   $_->wikiname ],
						'0', "\n",
					  ];
		}
		push @sidebar,
			'div', [ {class => 'linkshere'},
					 'h2', [{}, '0', "Pages which link here" ],
					 '0', "\n",
					 'ul', \@linksherediv,
					 '0', "\n",
				   ],
	}
	

	if (1)
	{
		my @navbar = {};
        my @references = $db->load('WikiEntryReference',
                                from_id => $fpi->wikiobj->id);
        my @linkrefs;

        for my $linkref (@references)
        {
            my $link = $db->load_one('WikiEntry', id => $linkref->to_id);
            push @linkrefs, $link;
        }
        @linkrefs = sort {$a->wikiname cmp $b->wikiname} @linkrefs;
        for my $link (@linkrefs)
        {
            if ($link->wikiname =~ /^Category\:/)
            {
                push @navbar, 
                    'li', [ {}, 'a',
                            [{ href => './'
                               .FbyParse::OutputNameToLinkName($link->outputname) },
                             '0', HTML::Entities::encode($link->wikiname)
                            ],
                            '0', "\n",
                          ];
            }
        }

		foreach (['Main_Page', 'Main Page'],
				 ['Categories', 'Categories'],
				['User%3aDanLyke', 'Dan Lyke'])
		{
			push @navbar,
				'li', [ {}, 'a', [ { href => $_->[0]},
								   '0',
								   $_->[1] ],
						'0', "\n",
					  ];
		}

		push @sidebar,
			'div', [ {class => 'navbar'},
					 'h2', [{}, '0', 'Navigation' ],
					 '0', "\n",
					 'ul', \@navbar,
					 '0', "\n",
				   ],
	}

	my $att = shift @$body;
	unshift @$body, $att, 'div', [ {class => 'sidebar'}, @sidebar];
	


	if (defined($title))
	{
		my $att = shift @$body;
		unshift @$body, $att, 
			'h1', [{}, '0', "$title"], 
				'0', "\n";
				
	}


	if ($login_manager)
	{
		my $att = shift @$body;
		unshift @$body, $att, 
			'div', [{ id => 'login'}, '0', ''], 
				'0', "\n";
				
	}
	
	my $r;
	my $output = Flutterby::Output::HTML->new();
	$output->setOutput(\$r);
	$output->output($tree);
	return $r;
}





sub CopyIfChanged($$@)
{
	my ($outputfile, $stagingfile, $sourcefile) = @_;
	$sourcefile = defined($sourcefile) 
		? "$sourcedir/".$sourcefile
			:
				$stagingfile;
 	if (-f $stagingfile) {
		my $changed;

		if (-f $outputfile) {
			open(F1, $stagingfile)
				|| die "Unable to open $stagingfile for reading\n".CallStack;
			open(F2, $outputfile)
				|| die "Unable to open $outputfile for reading\n".CallStack;

			my $l1 = join('', <F1>);
			my $l2 = join('', <F2>);
			close F1;
			close F2;
			$changed = 1 if ($l1 ne $l2);
		} else {
			$changed = 1;
		}

		if (defined($changed)) {
			print "Copying $stagingfile to $outputfile\n";
			open F1, $stagingfile
				|| die "Unable to open $stagingfile for reading\n".CallStack;
			$outputfile = $1 if ($outputfile =~ /^(.*)$/);
			$sourcefile = $1 if ($sourcefile =~ /^(.*)$/);
			open F2, ">$outputfile"
				|| die "Unable to open $outputfile for writing\n".CallStack;
			print F2 join('', <F1>);
			close F1;
			close F2;
			if (-f $sourcefile)
			{
				my $cmd = "/usr/bin/touch -r \"$sourcefile\" \"$outputfile\"";
				system($cmd);
			}
		}
	}
}


sub CopyWikiObjIfChanged($$)
{
	my ($fpi, $wikiobj) = @_;
	$fpi->wikiobj($wikiobj);
		
	my $outputname = FbyParse::ConvertTextToWiki($wikiobj->wikiname, 1);
	my $stagingfile = "$stagingdir/$outputname".$fpi->suffix;
	my $outputfile = "$outputdir/$outputname".$fpi->suffix;
	
	CopyIfChanged($outputfile, $stagingfile, 
				  $wikiobj->inputname);
	if ($outputname =~ /^Category:/)
	{
		$stagingfile = "$stagingdir/$outputname.rss";
		$outputfile = "$outputdir/$outputname.rss";
		CopyIfChanged($outputfile, $stagingfile, 
					  $wikiobj->inputname);
	}
}

sub DoRss($$)
{
	my ($fpi, $wikiobj) = @_;
	my $wikiname = $wikiobj->wikiname;
	$fpi->wikiobj($wikiobj);
	my $t = SingleFile($wikiobj,$fpi);

	return unless defined($t);
			
	my $rss = XML::RSS->new(version => '2.0');
	$rss->channel
		(
		 title => "Flutterby.net: $1",
		 link => 'http://www.flutterby.net/'
		 .FbyParse::ConvertTextToWiki($wikiobj->wikiname),
		 language => 'en',
		);
			
	my @refby = $wikiobj->referencedBy($db);
	foreach my $refby (@refby)
	{
	    if (defined($refby->inputname) && -f "$sourcedir/$refby->inputname")
	    {
            $refby->initStatStuff();
	    }
	}
#		my @entries = sort {$b->mtime() <=> $a->mtime()} @refby;
	my @entries = sort {$b->wikiname() cmp $a->wikiname()} @refby;
	@entries = grep {$_->wikiname =~ /^\d\d\d\d-\d\d-\d\d/} @entries
		if ($wikiname =~ /life/ || $wikiname =~ /posts/);

	for (my $i = 0; $i < 15 && $i < @entries; ++$i)
	{
		my $entry = $entries[$i];
		my $fn = "$stagingdir/".$entry->outputname;
		if (open(I, $fn))
		{
			my $t = join('',<I>);
			close I;
		
			$t =~ s/^.*?\<div\ class="content">//xsig;
			$t =~ s%</div><div\ class="footer">.*$%%xsig;
			$t =~ s%(href=)"./%$1"http://www.flutterby.net/%xsig;
			$t =~ s%(src=)"./%$1"http://www.flutterby.net/%xsig;
			$t =~ s%(href=)"/%$1"http://www.flutterby.net/%xsig;
			$t =~ s%(src=)"/%$1"http://www.flutterby.net/%xsig;

#			print "Adding title ".$entry->wikiname."\n";

			$rss->add_item(title => $entry->wikiname,
						   permaLink => 'http://www.flutterby.net/'.$entry->outputnameRoot.'.html',
						   description => $t,
						   dc => {date => email_date($entry->mtime())},
						  );
		}
		else
		{
			warn "Unable to open $fn for including in RSS feed\n".CallStack;
		}
	}
	my $savefilename = "$stagingdir/".$wikiobj->outputnameRoot.".rss";
	$savefilename = $1 if ($savefilename =~ /^(.*)$/);
	$rss->save($savefilename);
}

sub MarkWikiEntriesNeedingRebuildFromRefs($$)
{
	my ($db, $refs) = @_;
	foreach my $ref (@$refs)
	{
		my $toobj = $db->load_one('WikiEntry', id => $ref->to_id);
		$toobj->needsExternalRebuild(1);
		$db->write($toobj);
	}
}



sub DoWikiObj($$)
{
	my ($fpi, $wikiobj) = @_;
	confess("Undefined fpi\n") unless defined($fpi);
	confess("Undefined wikiobj\n") unless defined($wikiobj);
	confess("Undefined db\n") unless defined($fpi->db);

	$fpi->wikiobj($wikiobj);
	$fpi->googlemapnum(0);
		
	my $t = SingleFile($wikiobj,$fpi);
	return unless defined($t);
		
	my @nodes = Flutterby::Tree::Find::allNodes($t, 
												{
													'h1' => 1,
													'h2' => 1,
													'h3' => 1,
													'h4' => 1,
													'h5' => 1,
													'h6' => 1,
												});
	my @subsections;
	foreach my $node (@nodes) {
		my $out = Flutterby::Output::Text->new();
		my $t;
		$out->setOutput(\$t);
		$out->output($node->[1],1);
		my $n = "$node->[0]:".
			FbyParse::ConvertTextToWiki($t);
		push @subsections, [$node->[0], $t, $n];
		splice @{$node->[1]}, 1, 0, 'a', [{name=>$n,id=>$n}];
	}
	
	my @referencedby = $wikiobj->referencedBy($db);
	my @linkshere = sort {$a->wikiname cmp $b->wikiname} @referencedby;

	my $r = OutputTreeAsHTML($t,$wikiobj->wikiname, $fpi, \@subsections, \@linkshere);
	my $outfile = FbyParse::ConvertTextToWiki($wikiobj->wikiname, 1);
	my $fullpath = "$stagingdir/$outfile".$fpi->suffix;
	$fullpath = $1 if ($fullpath =~ /^(.*)$/);

	if (open O, ">$fullpath")
	{
		print O '<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN"  "http://www.w3.org/TR/html4/loose.dtd">';
		print O "\n";
		print O $r;
		close O;
	}
	else
	{
		warn "Unable to write to $fullpath\n";
	}
}


sub DoDirtyFiles()
{
	my $fpi = InstantiateFPI();


	my %allentries;
	my @entries = $db->load('WikiEntry', needsContentRebuild => 1);

	foreach my $wikiobj (@entries)
	{
		$allentries{$wikiobj->wikiname} = $wikiobj;
		print "Rebuilding ".$wikiobj->wikiname."\n";
		my @oldrefs = $db->load('WikiEntryReference',
								from_id => $wikiobj->id);

		$db->do('DELETE FROM WikiEntryReference WHERE from_id='.$wikiobj->id);
		DoWikiObj($fpi, $wikiobj);
		my @refs = $db->load('WikiEntryReference',
							 from_id => $wikiobj->id);

		my (%oldrefs, %refs, @rebuild);
		foreach my $ref (@oldrefs)
		{
			$oldrefs{join(',', $ref->from_id, $ref->to_id)} = $ref;
		}
		foreach my $ref (@refs)
		{
			$refs{join(',', $ref->from_id, $ref->to_id)} = $ref;
		}

		while (my ($id, $v) = each %oldrefs)
		{
			unless (exists($refs{$id}))
			{
				push @rebuild, $v;
			}
		}
		while (my ($id, $v) = each %refs)
		{
			unless (exists($oldrefs{$id}))
			{
				push @rebuild, $v;
			}
		}

		MarkWikiEntriesNeedingRebuildFromRefs($db, \@rebuild);
		$wikiobj->needsContentRebuild(0);
		$db->write($wikiobj);
		if ($wikiobj->wikiname =~ /^Category:\s*(.*)$/)
		{
			DoRss($fpi, $wikiobj);
		}
	}
	@entries = $db->load('WikiEntry', needsExternalRebuild => 1);

	foreach my $wikiobj (@entries)
	{
		$allentries{$wikiobj->wikiname} = $wikiobj;
#		print "Rebuilding external links for ".$wikiobj->wikiname."\n";
		DoWikiObj($fpi, $wikiobj);
		$wikiobj->needsContentRebuild(0);
		$wikiobj->needsExternalRebuild(0);
		$db->write($wikiobj);
	}

	foreach my $wikiobj (values %allentries)
	{
		CopyWikiObjIfChanged($fpi,$wikiobj);
	}
}

sub DoOneFile
{
    my @files = @_;

    my $fpi = InstantiateFPI();

    for my $file (@files)
    {
        my $wikifile = $file;
        $wikifile =~ s/^.*\///;
        $wikifile =~ s/\.wiki$//;

        my $wobj = FbyParse::LoadOneWikiEntry($db, $wikifile);
		DoWikiObj($fpi, $wobj);
    }
    
}


sub DoWikiFiles()
{
	my $fpi = InstantiateFPI();

	opendir IN_DIR, $sourcedir
		|| die "Unable to open directory '$sourcedir' for reading\n".CallStack;

	while (my $filename = readdir(IN_DIR))
	{
		if ($filename =~ /^(\w.*?).wiki$/)
		{
            print "Load or create $1\n";
			my $wobj = FbyParse::LoadOrCreateWikiEntry($db, $1);
		}
	}
	
	closedir IN_DIR;

	my @images = $db->load('Image');
	foreach my $image (@images)
	{
		my $wikiname = 'Image:'.$image->wikiname;
		my $filename = $wikiname.'.wiki';
        print "Load or create $wikiname\n";
		my $wobj = FbyParse::LoadOrCreateWikiEntry($db, $wikiname);
	}

	my %missingpages;

	my @wikiobjects = $db->load('WikiEntry');

	foreach my $wikiobj (@wikiobjects)
	{
		$fpi->wikiobj($wikiobj);
		$fpi->googlemapnum(0);
		
		
		my $t = SingleFile($wikiobj,$fpi);
		if (defined($t))
		{
			foreach (keys %{$wikiobj->_missingReferences})
			{
				$missingpages{$_} = [] unless (defined($missingpages{$_}));
				push @{$missingpages{$_}},$wikiobj;
			}
		}
	}
	
		
	foreach my $wikiobj (@wikiobjects)
	{
        print "Wiki object ".$wikiobj->wikiname."\n";
		DoWikiObj($fpi, $wikiobj);
        print "Done with wiki object\n";
	}
	
	foreach my $wikiobj (@wikiobjects)
	{
		my $wikiname = $wikiobj->wikiname;
		$fpi->wikiobj($wikiobj);
		$fpi->googlemapnum(0);
		
		if ($wikiname =~ /^Category:\s*(.*)$/)
		{
			DoRss($fpi, $wikiobj);
		}
	}
	
	
	
	foreach my $wikiobj (@wikiobjects)
	{
		CopyWikiObjIfChanged($fpi, $wikiobj);
	}
	
	
	if (0)
	{
		foreach (keys %missingpages)
		{
			print "Missing '$_' : ". join(', ', @{$missingpages{$_}})."\n";
		}
	}
}

sub DoEverything()
{
	my $fpi = InstantiateFPI();

	foreach my $subdirs ('wiki', 'files')
	{
		FindAllFiles($fpi, $sourcedir, $subdirs);
	}

	DoWikiFiles();
}




sub GetWikiFiles()
{
	my $fpi = InstantiateFPI();

	print map {"$_\n"} $fpi->GetWikiWikinames();
#	opendir IN_DIR, $sourcedir
#		|| die "Unable to open directory '$sourcedir' for reading\n".CallStack;
#	while (my $filename = readdir(IN_DIR))
#	{
#		print "$1\n" if ($filename =~ /^(\w.*?).wiki$/);
#
#	}
#	closedir IN_DIR;
}



sub WriteWikiFile()
{
	my ($wikifile) = @_;
	my $fpi = InstantiateFPI();

	$wikifile = $1 if ($wikifile =~ s/[><\/\\]//g);
	my $outfile = "$sourcedir/$wikifile.wiki";
	$outfile =~ /^(.*)$/;
	$outfile = $1;

	open(OUT, ">$outfile")
		|| die "Unable to open $sourcedir/$wikifile.wiki for writing\n".CallStack;

	while (<STDIN>)
	{
		print OUT $_;
	}
	close OUT;

	my $wobj = FbyParse::LoadOrCreateWikiEntry($db, $wikifile);
	$wobj->needsContentRebuild(1);
	$wobj->inputname("$wikifile.wiki");
	my @refs = $db->load('WikiEntryReference',
						 from_id => $wobj->id);
	MarkWikiEntriesNeedingRebuildFromRefs($db, \@refs);
	$db->write($wobj);
	$db->delete('WikiEntryReference', from_id => $wobj->id);
}



sub UploadFileToMediawiki($$$$)
{
	my ($mw, $pagename, $pagetext, $data) = @_;

	my $tries = 8;

	while ($tries > 0 && !$mw->upload( { title => $pagename,
				   summary => $pagetext,
				   data => $data } ))
	{
		warn "Error uploading $pagename".
			$mw->{error}->{code} . ': ' . $mw->{error}->{details}."\n";
		--$tries;
	}
	die $mw->{error}->{code} . ': ' . $mw->{error}->{details} if (!$tries);
	my $resp = get("http://new.flutterby.net/Image:$pagename");
}

sub LoadFileIntoMemory($)
{
	my ($file) = @_;
	open FILE, $file or die "$! $file\n";
	binmode FILE;
	my ($buffer, $data);
	while ( read(FILE, $buffer, 65536) )  {
		$data .= $buffer;
	}
	close(FILE);
	return $data;
}

sub MediaWikiUpload($$$)
{
	my ($fpi, $basename, $filename) = @_;

	use LWP::Simple;
	use MediaWiki::API;

	my $mw = MediaWiki::API->new();

	$mw->{config}->{api_url} = 'http://new.flutterby.net/wiki/api.php';
	$mw->{config}->{upload_url} = 'http://new.flutterby.net/Special:Upload';
	$mw->login( { lgname => 'DanLyke', lgpassword => '&F3$kl2' } )
		|| die $mw->{error}->{code} . ': ' . $mw->{error}->{details};

	print "Processing $filename\n";

	open I, "jhead '$filename' |"
		|| die "Unable to run jhead on '$filename'\n";

	my ($width, $height, $rotation);
		
	while (<I>)
	{
		if (/^Resolution\ +\:\ *(\d+)\ *x\ *(\d+)/)
		{
			$width = $1;
			$height = $2;
		}
		if (/^Orientation\s+\:\s+rotate\s+([\-\+]?\d+)/)
		{
			$rotation = $1;
			print "Got rotation $rotation\n";
		}
	}
	close I;
	print "$filename is $width x $height\n";
		
	my $copied;

	if (defined($width) && $width > 0)
	{
		foreach my $dim (['full', 1280, 1024, 400])
		{
			my ($pos,$n, $s, $minw) = @$dim;
			my $doConversion;
			my $nw = ($width>$height)?
				(int(($height * $s / $width + 7)/8) * 8) : (int(($width * $s / $height + 7)/8) * 8);
			if ($nw < $minw)
			{
				$s = ($width>$height)?
					($minw * $width / $height) : ($minw * $height / $width);
				$nw = ($width>$height)?
					(int(($height * $s / $width + 7)/8) * 8) : (int(($width * $s / $height + 7)/8) * 8);
			}
			if ($width > $height)
			{
				$doConversion = 1 if ($width > $n || $width < ($n / 4));
				$s = sprintf('%dx%d', $s,$nw);
			}
			else
			{
				$doConversion = 1 if ($height > $n || $height < ($n / 4));
				$s = sprintf('%dx%d', $nw,$s);
			}
			my $path = '/home/danlyke/tmp';
			my $cmd = "convert '$filename' -size $s -scale '$s>!' '$path/$basename'";
			if (defined($doConversion))
			{
				print "$cmd\n";
				system($cmd);
				system("jhead -te $filename $path/$basename");
				if (defined($rotation))
				{
					# system("rotate $rotation $path/$filename");
					system("jhead -autorot $path/$basename");
				}
			}
			else
			{
				$copied = 1;
				my $cmd = "cp $filename $path/$basename";
				$cmd = $1 if ($cmd =~ /^(.*)$/);
				system($cmd);
			}
			
			my $data = LoadFileIntoMemory("$path/$basename");
			my $pn = "$basename";
			my $jheadcmd = "jhead \"$path/$basename\"";
			$jheadcmd = $1 if ($jheadcmd =~ /^(.*)$/);
			my $t = `$jheadcmd`;
			UploadFileToMediawiki($mw, "$path/$basename", $t, $data);
			my $tries = 3;
			while ($tries > 0 && 
				   !get('http://new.flutterby.net/Image:'.$basename))
			{
				--$tries;
			}
			$pn =~ s/^.*\///;
		}
	}
}

sub WriteImageFile()
{
	my ($imagefile) = @_;
	my $fpi = InstantiateFPI();

	my $db = $fpi->db;
	my $outputdir = $fpi->outputdir;

	my $fhout;
	my $localdir = '';

	$imagefile =~ s/[^\w\-\.]//xsig;
	if ($imagefile =~ /^(\d{4})\-(\d{2})\-(\d{2})/)
	{
		$localdir = "$1/$2/$3";
	}
	else
	{
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
			localtime(time);
		$localdir = sprintf("%4.4d/%2.2d/%2.2d", $year+1900,$mon+1,$mday);
	}

	my $targetdir = "$outputdir/files/images/$localdir";
	my $targetfile = "$targetdir/$imagefile";
	$targetfile = $1 if ($targetfile =~ /^(.*)$/);
	system "mkdir -p \"$targetdir\"";
	open($fhout, '>', $targetfile)
		|| die "Unable to open $targetfile for writing\n";

	my $buffer;

	binmode STDIN;
	binmode $fhout;

	while (0 < (my $len = read(STDIN, $buffer, 16384)))
	{
		print $fhout $buffer;
	}
	close $fhout;

	MediaWikiUpload($fpi, $imagefile, $targetfile);

	my $tagfile = "$sourcedir/Status Uploaded Images.wiki";
	open($fhout, '>>', $tagfile)
		|| die "Unable to open $tagfile for writing\n".CallStack;
	print $fhout "[[Image:$imagefile]]\n";
	close $fhout;

	print "Loading image $imagefile\n";
	my $image = $db->load_or_create('Image', 
									wikiname=> $imagefile);
	my $instance = $image->thumb($db);
	print "Wiki Name: Image:$imagefile\n";
	print "Thumbnail: ".$instance->width." x ".$instance->height." ".$instance->filename."\n";
}

sub ReadWikiFile()
{
	my ($wikifile) = @_;
	my $fpi = InstantiateFPI();

	print FbyParse::LoadFileText($fpi, $fpi->sourcedir."/$wikifile.wiki");
}


sub RebuildDetached()
{
	my $fpi = InstantiateFPI();

	my $cmd = "setsid sh -c './bin/fby.pl dowikifiles \& :' > /dev/null 2>\&1 < /dev/null";
	system($cmd);
}

sub GetISO8601Day()
{
    my ($mday,$mon,$year) = (localtime(time))[3..5];
    return sprintf("%04.4d-%02.2d-%02.2d", $year + 1900, $mon + 1, $mday);
}


sub FindLatestNumInDir($)
{
    my ($dir) = @_;
    opendir(NID, $dir)
	|| die "FindLatestNumInDir: Unable to open $dir\n".CallStack;
    my $highest = -1;

    while (my $file = readdir(NID))
    {
	if ($file =~ /^\d+$/)
	{
	    $highest = $file if ($file > $highest);
	}
    }
    closedir NID;
    return $highest;
}

sub ImportKML()
{
	my ($subject, $categories, $directory) = @_;
	$directory = $1 if ($directory =~ /^(.*)$/);
	my $config = ReadConfig();
	$subject =~ s/[^\w\ ]//xsig;

	my $isoday = GetISO8601Day();

	my $target = $outputdir;
	my $kmlpath = ''; 

	foreach ('kml', $isoday)
	{
		$target .= "/$_";
		$kmlpath .= "/$_";
		print "Making $target\n";
		mkdir $target;
	}
	my $dirnum = FindLatestNumInDir($target);
	++$dirnum;
	$target .= "/$dirnum";
	$kmlpath .= "/$dirnum";
	$target = $1 if ($target =~ /^(.*)$/);
	mkdir $target;


	opendir(DI, $directory)
		|| die "Unable to open $directory\n".CallStack;
	my @files = grep {/^[^\.]/} readdir DI;
	closedir DI;

	print "Found files ".join(', ', @files)."\n";

	my $kmlfile;

	foreach (@files)
	{
		$kmlfile = $_ if /\.kml$/i;
	}

	die "Unable to find KML file\n".CallStack
		unless defined($kmlfile);

	chdir $directory
	    || die "Unable to chdir to $directory: $!\n".CallStack;

	my $targetkmz = "$target/GPSLog.kmz";
	$targetkmz = $1 if ($targetkmz =~ /^(.*)$/);
	for (my $i = 0; $i < @files; ++$i)
	{
	    $files[$i] =$1 if ($files[$i] =~ /^(.*)$/);
	}
	print "In $directory, about to execute zip $target/GPSLog.kmz @files\n";
	system('zip',
	       "$target/GPSLog.kmz",
	       @files);
	system('cp',
		   @files,
		   $target);
	chdir $config->{InstallDir};

	print "Processing $target/$kmlfile\n";

    open(I,"$target/$kmlfile")
		|| die "Unable to open $target/$kmlfile\n".CallStack;
    my $t = join('', <I>);
    close I;

    $t =~ s%(img src\=\")(\w)%$1$kmlpath/$2%g;
	my $targetkmlfile = "$target/$kmlfile";
	$targetkmlfile = $1 if $targetkmlfile =~ /^(.*)$/;

    open(O, ">$targetkmlfile")
		|| die "Unable to open $target/$kmlfile for writing\n".CallStack;
    print O $t;
    close O;

    my ($minlat,$minlon, $maxlat, $maxlon) = (999,999,-999,-999);
    while ($t =~ s/\<coordinates\>([\-0-9\.]+?)\,([\-0-9\.]+?)(\,[\-0-9\.]+?)?\<\/coordinates\>//)
    {
		$minlon = $1 if ($1 < $minlon);
		$minlat = $2 if ($2 < $minlat);
		$maxlon = $1 if ($1 > $maxlon);
		$maxlat = $2 if ($2 > $maxlat);
    }

    my $wikikmlfile = "$sourcedir/$isoday $subject.wiki";

	my @categories = ('KML Files',	split(/ *\, */, $categories));
    $t = join(' ', map{'[[Category: '.$_.']]'} @categories);

    if (-f $wikikmlfile)
    {
		open(I, $wikikmlfile)
			|| die "Unable to open $wikikmlfile\n".CallStack;
		$t = join('', <I>);
		close I;
    }

    if ($t !~ /\=\= KML \$dirnum \=\=/)
    {
		my $lat = ($minlat + $maxlat) / 2;
		my $lon = ($minlon + $maxlon) / 2;
		my $newt = <<EOF;

== KML $dirnum ==

Here is <a href="$kmlpath/GPSLog.kmz"</a>the KMZ for $isoday $dirnum</a>,
centered at lat=$lat lon=$lon, KML is at $kmlpath/GPSLog.kml
			
<googlemap version="0.9" lat="$lat" lon="$lon" zoom="12">
kml:http://www.flutterby.net$kmlpath/$kmlfile
</googlemap>

EOF

$wikikmlfile = $1 if $wikikmlfile =~ /^(.*)$/;
		open(O, ">$wikikmlfile")
			|| die "Unable to open $wikikmlfile for writing\n".CallStack;
		print O "$newt$t";
		close O;
    }
}


sub ScanDPLFiles()
{
	my $fpi = InstantiateFPI();

	opendir IN_DIR, $sourcedir
		|| die "Unable to open directory '$sourcedir' for reading\n".CallStack;
	my @files = readdir IN_DIR;
	closedir IN_DIR;
	foreach my $filename (@files)
	{
		if ($filename =~ /^(\w.*?).wiki$/)
		{
			my $wikiname = $1;
			if (open(I,"$sourcedir/$filename"))
			{
                my $oldsig = $SIG{__WARN__};
                $SIG{__WARN__} = sub { print STDERR "$filename ($.): ".join(', ', @_)."\n"; };

				my $t = join('', <I>);
                $SIG{__WARN__} = $oldsig;
				close I;
				if ($t =~ /\<DPL/xsig)
				{
					my $wikientry = FbyParse::LoadOrCreateWikiEntry($db,$wikiname);
					$wikientry->inputname($filename);
					$wikientry->needsContentRebuild(1);
					$db->write($wikientry);
				}
			}
		}
	}
	DoDirtyFiles();
}



sub DoChangedFiles()
{
	my $fpi = InstantiateFPI();

	my $lastchanged = 0;

	if (-f $lastscanfilename)
	{
		my @stat = stat($lastscanfilename);
		$lastchanged = $stat[9];
	}
	if (open O, ">$lastscanfilename")
	{
		close O;
	}

	opendir IN_DIR, $sourcedir
		|| die "Unable to open directory '$sourcedir' for reading\n".CallStack;
	while (my $filename = readdir(IN_DIR))
	{
		if ($filename =~ /^(\w.*?)\.(wiki|html)$/)
		{
			my $wikiname = $1;
			my @stat = stat("$sourcedir/$filename");
			if ($stat[9] > $lastchanged)
			{
				my $wikientry = FbyParse::LoadOrCreateWikiEntry($db, $wikiname);
				$wikientry->inputname($filename);
				$wikientry->needsContentRebuild(1);
				$db->write($wikientry);
			}
		}
	}
	closedir IN_DIR;
	DoDirtyFiles();
}

sub LoadEXIFData()
{
    my (@imagelist) = @_;
    my $fpi = InstantiateFPI();
    my $db = $fpi->db;
    my $terms = ' WHERE set_flags ISNULL';
    $terms = ' WHERE '.join(' OR ', map { "wikiname=".$db->quote($_) } @imagelist)
        if (@imagelist);
    my $st = $db->prepare('Image', $terms);
    my $camera;

    while (my $img = $st->fetchrow())
    {
        my @insts = $img->instanceslargetosmall($db);
        for my $instance (@insts)
        {
			if (open(my $fh, '-|', "jhead '".$instance->filename."'"))
			{
                my %m;
				while (my $line = <$fh>)
				{
					chomp $line;
					$camera = $1 if ($line =~ /Camera model \: (.*)/i);

                    my %keys =
                        (
                         exiftime => 'Date\/Time\s*\:\s*(.*)',
                         focallength => 'Focal\slength\s*:.*35mm equivalent\:\s*(.*)mm',
                         exposuretime => 'Exposure\stime\s*:\s*([\d\.]+) s',
                         aperture => 'Aperture\s*\:\s*f\/([\d\.]+)',
                         focusdist => 'Focus\sdist\.\s*\:\s*([\d\.]+)m',
                         altitude => 'GPS\sAltitude\s*:\s*([\d.]+)m',

                        );

                    while (my($k, $v) = each %keys)
                    {
                        if ($line =~ /$v/)
                        {
                            $m{$k} = $1
                        }
                    }

                    if ($line =~ /GPS\s+Latitude\s*\:\s*([NS])\s*(\d+)d\s*(\d+)m\s*([\d\.]+)s/)
                    {
                        my $l = ($1 eq 'N' ? '' : '-').$2.($3/60+$4/3600);
                        $m{latitude} = $l / 10;
                    }
                    if ($line =~ /GPS\s+Longitude\s*\:\s*([WE])\s*(\d+)d\s*(\d+)m\s*([\d\.]+)s/)
                    {
                        my $l = ($1 eq 'E' ? '' : '-').$2.($3/60+$4/3600);
                        $m{longitude} = $l / 10;
                    }


				}

                my $needswrite = 0;

                if (defined($m{exiftime}))
                {
                    $m{exiftime} =~ s/^(\d+)[\/\:](\d+)[\/\:]/$1-$2-/g;
                    $m{exiftime} =~ s/^(\d+)[\/\:](\d+)[\/\:]/$1-$2-/g;
                }

                for (my $i = 0; $i < @{$img->set_flag_keys()}; $i++)
                {
                    my $k = $img->set_flag_keys->[$i];
                    if (defined($m{$k}))
                    {
                        $needswrite |= (1 << $i);
                        $img->$k($m{$k});
                    }
                }

                if (defined($camera))
                {
#                    print "Found $camera / $m{exiftime} / $m{focallength} / $m{exposuretime} / $m{aperture} / $m{focusdist} for image ".$img->wikiname."\n";
                    my $cam = $db->load_or_create('Camera', name => $camera);
                    $img->camera_id($cam->id);
                }

                if ($needswrite)
                {
                    print "Writing ".$img->wikiname."\n";

                    $needswrite |= $img->set_flags if ($img->set_flags);
                    $img->set_flags($needswrite);
                    $db->write($img);
                }

            }
			else
			{
				warn "Missing instance ".$instance->filename."\n";
			}
        }
    }

}


sub ScanImages()
{
    my $fpi = InstantiateFPI();
    $imageinstances = {};

    my $db = $fpi->db;
    my $st = $db->prepare('ImageInstance');
    while (my $inst = $st->fetchrow())
    {
        $imageinstances->{$inst->filename} = 1;
    }

    foreach my $subdirs ('wiki', 'files')
    {
        FindUntrackedImages($fpi, $sourcedir, $subdirs);
    }
    
    undef $imageinstances;
    DoChangedFiles();
}



sub commands()
{
	return 
	{
	 'doeverything' => \&Fby::DoEverything,
	 'dowikifiles' => \&Fby::DoWikiFiles,
	 'getwikifiles' => \&Fby::GetWikiFiles,
	 'writewikifile' => \&Fby::WriteWikiFile,
	 'writeimagefile' => \&Fby::WriteImageFile,
	 'readwikifile' => \&Fby::ReadWikiFile,
	 'rebuilddetached' => \&Fby::RebuildDetached,
	 'importkml' => \&Fby::ImportKML,
	 'dodirtyfiles' => \&Fby::DoDirtyFiles,
	 'dochangedfiles' => \&Fby::DoChangedFiles,
	 'scanimages' => \&Fby::ScanImages,
	 'loadexifdata' => \&Fby::LoadEXIFData,
	 'scandplfiles' => \&Fby::ScanDPLFiles,
     'doonefile' => \&Fby::DoOneFile,
	};
}


1;

=head1 NAME

Fby - The interface to the Flutterby.net wiki system

=head1 SYNOPSIS

Right now this is just a dumbing ground for the actual contents of a
script that does some SUID stuff and then calls the functions
retrieved from the hash returned by the Fby::commands subroutine.

=head1 DESCRIPTION

Available commands:

=head2 &{Fby::commands->{'doeverything'}}()

Find all image files, make sure they have .wiki files, and then
rebuild the wiki files. This is a great function to have but should
eventually go away as the system gets smarter.

=head2 &{Fby::commands->{'dowikifiles'}()

Rebuild all of the wiki files, but don't do the image scan.

=head2 &{Fby::commands->{'getwikifiles'}()

Get a list of all of the wiki files

=head2 &{Fby::commands->{'writewikifile'}('Wiki entry name')

Write an individual wiki file from STDIN to the wiki file repository.

=head2 &{Fby::commands->{'readwikifile'}('Wiki entry name')

Read an individual wiki file from STDIN from the wiki file repository.

=head2 &{Fby::commands->{'rebuilddetached'}()

Respawn './bin/fby.pl dowikifiles' as an setsid detached process.

=head2 &{Fby::commands->{'importkml'}('subject', 'categories', 'directory')

Import a KML file, creating a 'YYYY-MM-DD subject' Wiki file
referencing the comma separated categories listed, and an embedded
Google map.

'directory' is where to find the KML file.

=head2 &{Fby::commands->{'dodirtyfiles'}()

Just rebuild the files that have been marked dirty, right now just by
'writewikifile'.

=head2 &{Fby::commands->{'dochangedfiles'}()

Look for changed files and rewrite them as dirty.
