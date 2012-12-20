#!/usr/bin/perl -w
use strict;
use warnings;
use HTML::Entities;
use Mail::Sendmail;

package SendMail;

sub SendMail($$$$)
{
    my ($fromemail, $toemail, $subject, $text) = @_;

    my $boundary = "====" . time() . "====";

    my %mail = 
	(
	 from => $fromemail,
         to => $toemail,
         subject => $subject,
         'content-type' => "multipart/alternative; boundary=\"$boundary\""
	 );

    my $plain = $text;

    my $html = encode_entities($text);
    $html =~ s%(http://.*?)(\s)%<a href="$1">$1</a>$2%xsg;
    $html =~ s/\n\n/\n\n<p>/g;
    $html =~ s/\n/<br>\n/g;
    $html = "<p><strong>" . $html . "</strong></p>";

    $boundary = '--'.$boundary;

    $mail{body} = <<END_OF_BODY;
$boundary
Content-Type: text/plain; charset="utf-8"
Content-Transfer-Encoding: 7bit

$plain

$boundary
Content-Type: text/html; charset="utf-8"
Content-Transfer-Encoding: 7bit

<html>$html</html>
$boundary--
END_OF_BODY

    sendmail(%mail) || print "Error: $Mail::Sendmail::error\n";
}

1;
