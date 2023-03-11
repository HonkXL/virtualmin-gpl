#!/usr/local/bin/perl
# Quickly show overview information about a domain

require './virtual-server-lib.pl';
&ReadParse();
$d = &get_domain($in{'dom'});
$d || &error($text{'edit_egone'});
&can_edit_domain($d) || &error($text{'edit_ecannot'});
if ($d->{'parent'}) {
	$parentdom = &get_domain($d->{'parent'});
	}
if ($d->{'alias'}) {
	$aliasdom = &get_domain($d->{'alias'});
	}
if ($d->{'subdom'}) {
	$subdom = &get_domain($d->{'subdom'});
	}
$tmpl = &get_template($d->{'template'});

&ui_print_header(&domain_in($d), $aliasdom ?  $text{'summary_title3'} :
                                 $subdom ?    $text{'summary_title4'} :
                                 $parentdom ? $text{'summary_title2'} :
                                              $text{'summary_title'}, "");
@tds = ( "width=30%" );
print &ui_table_start($text{'edit_header'}, "width=100%", 4);

# Domain name (with link), user and group
if (&domain_has_website($d)) {
	my $url = &get_domain_url($d, 1);
	print &ui_table_row($text{'edit_domain'},
	    "<tt>".&ui_link($url, $d->{'dom'}, undef, "target=_blank")."</tt>",
	    undef, \@tds);
	}
else {
	print &ui_table_row($text{'edit_domain'},
			    "<tt>$d->{'dom'}</tt>", undef, \@tds);
	}

# Default domain
if ($d->{'defaultdomain'}) {
	print &ui_table_row($text{'wizard_defdom_desc'},
			    $text{'yes'}, undef, \@tds);
	}

# Creator
print &ui_table_row($text{'edit_created'},
	$d->{'creator'} ? &text('edit_createdby', &make_date($d->{'created'},1),
						  $d->{'creator'})
			: &make_date($d->{'created'}),
	$d->{'creator'} ? 3 : 1, \@tds);

# Owner
my $owner = "<tt>$d->{'user'}</tt>";
if (&can_edit_domain($d) && &can_rename_domains()) {
	$owner = "<a href='rename_form.cgi?dom=$d->{'id'}'>$owner</a>"
	}
print &ui_table_row($text{'edit_user'}, $owner,
		    undef, \@tds);
if (!$d->{'parent'}) {
	my $gr = $d->{'unix'} &&
	          $d->{'group'} ? "<tt>$d->{'group'}</tt>" : $text{'edit_nogroup'};
	if (&can_edit_domain($d) && &can_rename_domains()) {
		$gr = "<a href='rename_form.cgi?dom=$d->{'id'}'>$gr</a>"
		}
	print &ui_table_row($text{'edit_group'},
		    $gr,
		    undef, \@tds);
	}

# Show user and group quotas
if (&has_home_quotas() && !$parentdom) {
	my $uq = $d->{'quota'} ? &quota_show($d->{'quota'}, "home")
			  : $text{'form_unlimit'};
	if (&can_config_domain($d)) {
		$uq = "<a href='edit_domain.cgi?dom=$d->{'id'}'>$uq</a>"
		}
	print &ui_table_row($text{'edit_quota'}, $uq, 1, \@tds);

	my $uuq = $d->{'uquota'} ? &quota_show($d->{'uquota'}, "home")
			   : $text{'form_unlimit'};
	if (&can_config_domain($d)) {
		$uuq = "<a href='edit_domain.cgi?dom=$d->{'id'}'>$uuq</a>"
		}
	print &ui_table_row($text{'edit_uquota'}, $uuq, 1, \@tds);
	}


# IP-related options
if (!$aliasdom) {
	if (defined(&get_reseller)) {
		foreach $r (split(/\s+/, $d->{'reseller'})) {
			$resel = &get_reseller($r);
			if ($resel && $resel->{'acl'}->{'defip'}) {
				$reselip = $resel->{'acl'}->{'defip'};
				$reselip6 = $resel->{'acl'}->{'defip6'};
				}
			}
		}
	my $ip = "<tt>$d->{'ip'}</tt>";
	if (&can_change_ip($d) && &can_edit_domain($d)) {
		$ip = "<a href='newip_form.cgi?dom=$d->{'id'}'>$ip</a>"
		}
	print &ui_table_row($text{'edit_ip'},
		   "$ip ".($d->{'virt'} ? $text{'edit_private'} :
		   $d->{'ip'} eq $reselip ? &text('edit_rshared',
						  "<tt>$resel->{'name'}</tt>") :
					    $text{'edit_shared'}), 3, \@tds);
	}
if ($d->{'ip6'} && !$aliasdom) {
	my $ipv6 = "<tt>$d->{'ip6'}</tt>";
	if (&can_change_ip($d) && &can_edit_domain($d)) {
		$ipv6 = "<a href='newip_form.cgi?dom=$d->{'id'}'>$ipv6</a>"
		}
	print &ui_table_row($text{'edit_ip6'},
		"$ipv6 ".($d->{'virt6'} ? $text{'edit_private'} :
		 $d->{'ip6'} eq $reselip6 ? &text('edit_rshared',
						  "<tt>$resel->{'name'}</tt>") :
			       		    $text{'edit_shared'}), 3, \@tds);
	}

# Plan, if any
if ($d->{'plan'} ne '') {
	my $plan = &get_plan($d->{'plan'});
	my $plan_name = $plan->{'name'};
	if (&can_config_domain($d)) {
		$plan_name = "<a href='edit_domain.cgi?dom=$d->{'id'}'>$plan_name</a>"
		}
	print &ui_table_row($text{'edit_plan'}, $plan_name, undef, \@tds);
	}

if ($aliasdom) {
	# Alias destination
	print &ui_table_row($text{'edit_aliasto'},
	   "<a href='view_domain.cgi?dom=$d->{'alias'}'>".
	    &show_domain_name($aliasdom)."</a>",
	   undef, \@tds);
	}
elsif (!$parentdom) {
	# Contact email address
	my $domemail = &html_escape($d->{'emailto'});
	if (&can_config_domain($d)) {
		$domemail = "<a href='edit_domain.cgi?dom=$d->{'id'}'>$domemail</a>"
		}
	print &ui_table_row($text{'edit_email'},
			    $domemail, undef, \@tds);
	}
else {
	# Show link to parent domain
	print &ui_table_row($text{'edit_parent'},
	    "<a href='view_domain.cgi?dom=$d->{'parent'}'>".
	     &show_domain_name($parentdom)."</a>",
	    undef, \@tds);
	}

# Home directory
if (!$aliasdom && $d->{'dir'}) {
	my $domhome = "<tt>$d->{'home'}</tt>";
	if (&domain_has_website($d) && $d->{'dir'} &&
          !$d->{'proxy_pass_mode'} && &foreign_available("filemin")) {
		my $phd = &public_html_dir($d);
		my %faccess = &get_module_acl(undef, 'filemin');
		my @ap = split(/\s+/, $faccess{'allowed_paths'});
		if (@ap == 1) {
			if ($ap[0] eq '$HOME' &&
			    $base_remote_user eq $d->{'user'}) {
				$ap[0] = $d->{'home'};
				}
			$phd =~ s/^\Q$ap[0]\E//;
			}
		$domhome = "<a href=\"@{[&get_webprefix_safe()]}/filemin/index.cgi?path=@{[&urlize($phd)]}\">$domhome</a>";
		}
	print &ui_table_row($text{'edit_home'}, $domhome, 3, \@tds);
	}

# Description
if ($d->{'owner'} && 
	$d->{'owner'} ne $text{'wizard_defdom_desc'}) {
	my $owner = $d->{'owner'};
	if (&can_config_domain($d)) {
		$owner = "<a href='edit_domain.cgi?dom=$d->{'id'}'>$owner</a>"
		}
	print &ui_table_row($text{'edit_owner'}, $owner, 3, \@tds);
	}

# Show domain ID
if (&master_admin()) {
	my $domid = "<tt>$d->{'id'}</tt>";
	if (&foreign_available('filemin')) {
		my $efile = &urlize("$domains_dir/$d->{'id'}");
		my $qfile = &quote_escape("$domains_dir/$d->{'id'}");
		$domid = "<a data-dom-file=\"$qfile\" href=\"@{[&get_webprefix_safe()]}/filemin/edit_file.cgi?file=$efile\">$domid</a>";
		}
	print &ui_table_row($text{'edit_id'},
			    $domid, 3);
	my $now = time();

	# Show SSL cert expiry date and add color based on time
	if ($exptime = &get_ssl_cert_expiry($d)) {
		my $exp = &make_date($exptime);
		if ($now > $exptime) {
			$exp = &ui_text_color($exp, 'danger');
			}
		elsif ($now > $exptime - 7*24*60*60) {
			$exp = &ui_text_color($exp, 'warn');
			}
		if (&can_edit_domain($d) && &can_edit_ssl()) {
			$exp = "<a class=\"no-color\" href='cert_form.cgi?dom=$d->{'id'}'>$exp</a>"
			}
		print &ui_table_row($text{'edit_ssl_exp'}, $exp, 3);
		}

	# Show domain registration expiry date and add color based on time
	if ($d->{'whois_expiry'}) {
		my $exp = &make_date($d->{'whois_expiry'});
		if ($now > $d->{'whois_expiry'}) {
			$exp = &ui_text_color($exp, 'danger');
			}
		elsif ($now > $d->{'whois_expiry'} - 7*24*60*60) {
			$exp = &ui_text_color($exp, 'warn');
			}
		print &ui_table_row($text{'edit_whois_exp'}, $exp, 3);
		}
	}

print &ui_table_end();

# Make sure the left menu is showing this domain
if (defined(&theme_select_domain)) {
	&theme_select_domain($d);
	}

&ui_print_footer("", $text{'index_return'});

