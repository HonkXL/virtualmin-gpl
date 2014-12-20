# Provide more system info blocks specific to Virtualmin

require 'virtual-server-lib.pl';

sub list_system_info
{
my ($data, $in) = @_;

my @rv;
my $info = &get_collected_info();
my @poss = $info ? @{$info->{'poss'}} : ( );

# XXX resellers and domain owners and extra admins!

# Check for wizard redirect
my $redir = &wizard_redirect();
if ($redir) {
	push(@rv, { 'type' => 'redirect',
		    'url' => $redir });
	}

# Custom URL redirect
if ($data->{'alt'} && !$in{'noalt'}) {
	push(@rv, { 'type' => 'redirect',
		    'url' => $data->{'alt'} });
	}

# Warning messages
foreach my $warn (&list_warning_messages()) {
	push(@rv, { 'type' => 'warning',
		    'level' => 'warn',
		    'warning' => $warn });
	}

# Need to check module config?
if (&need_config_check() && &can_check_config()) {
	push(@rv, { 'type' => 'warning',
		    'level' => 'info',
		    'warning' => &ui_form_start('/'.$module_name.'/check.cgi').
				 "<b>$text{'index_needcheck'}</b><p>\n".
				 &ui_submit($text{'index_srefresh'}).
				 &ui_form_end(),
		  });
	}

# Virtualmin package updates
my $hasposs = foreign_check("security-updates");
my $canposs = foreign_available("security-updates");
if (!$data->{'noupdates'} && $hasposs && $canposs && @poss) {
	my $html = &ui_form_start("/security-updates/update.cgi");
	$html .= &text(@poss > 1 ? 'right_upcount' : 'right_upcount1',
		       scalar(@poss),
		       '/security-updates/index.cgi?mode=updates')."<p>\n";
	$html .= &ui_columns_start([ $text{'right_upname'},
                                     $text{'right_updesc'},
                                     $text{'right_upver'} ], "80%");
	foreach my $p (@poss) {
		$html .= &ui_columns_row([
			$p->{'name'}, $p->{'desc'}, $p->{'version'} ]);
		$html .= &ui_hidden("u", $p->{'update'}."/".$p->{'system'});
		}
	$html .= &ui_columns_end();
	$html .= &ui_form_end([ [ undef, $text{'right_upok'} ] ]);
	push(@rv, { 'type' => 'html',
		    'id' => 'updates',
		    'desc' => $text{'right_updatesheader'},
		    'html' => $html });
	}

# Status of various servers
if (!$data->{'nostatus'} && $info->{'startstop'} &&
    &can_stop_servers()) {
	my @ss = @{$info->{'startstop'}};
	my @down = grep { !$_->{'status'} } @ss;
	my @table;
	my $idir = '/'.$module_name.'/images';
	foreach my $status (@ss) {
		# Work out label, possibly with link
		my $label;
		foreach my $l (@{$status->{'links'}}) {
			if ($l->{'manage'}) {
				$label = &ui_link($l->{'link'},
						  $status->{'name'});
				}
			}
		$label ||= $status->{'name'};

		# Stop / start icon
		my $action = ($status->{'status'} ? "stop_feature.cgi" :
			      "start_feature.cgi");
		my $action_icon = ($status->{'status'} ?
		   "<img src='$idir/stop.png' alt='$status->{'desc'}' />" :
		   "<img src='$idir/start.png' alt='$status->{'desc'}' />");
		my $action_link = "<a href='/$module_name/$action?".
		   "feature=$status->{'feature'}'".
		   " title='$status->{'desc'}'>".
		   "$action_icon</a>";

		# Restart link 
		my $restart_link = ($status->{'status'}
		   ? "<a href='/$module_name/restart_feature.cgi?".
		     "feature=$status->{'feature'}'".
		     " title='$status->{'restartdesc'}'>".
		     "<img src='$idir/reload.png'".
		     "alt='$status->{'restartdesc'}'></a>\n"
		   : "");

		push(@table, { 'desc' => $label,
			       'value' =>
			(!$status->{'status'} ?
			      "<img src='$idir/down.gif' alt='Stopped'>" :
			      "<img src='$idir/up.gif' alt='Running'>").
		        $action_link.
		        "&nbsp;".$restart_link });
		}
	push(@rv, { 'type' => 'table',
		    'id' => 'status',
		    'desc' => $text{'right_statusheader'},
		    'open' => @down ? 1 : 0,
		    'table' => \@table });
	}

# New features
my @doms = &list_visible_domains();
if ($data->{'dom'}) {
	$defdom = &get_domain($data->{'dom'});
	if ($defdom && !&can_edit_domain($defdom)) {
		$defdom = undef;
		}
	}
if (!$defdom && @doms) {
	$defdom = $doms[0];
	}
my $newhtml = &get_new_features_html($defdom);
if ($newhtml) {
	push(@rv, { 'type' => 'html',
		    'id' => 'newfeatures',
		    'open' => 1,
		    'desc' => $text{'right_newfeaturesheader'},
		    'html' => $newhtml });
	}

# Virtualmin feature counts

# Top quota users

# Top BW users

# IP addresses used

# Programs and versions
if (!$data->{'nosysinfo'} && $info->{'progs'} && &can_view_sysinfo()) {
	my @table;
	foreach my $info (@{$info->{'progs'}}) {
		push(@table, { 'desc' => $info->[0],
			       'value' => $info->[1] });
		}
	push(@rv, { 'type' => 'table',
		    'id' => 'sysinfo',
		    'desc' => $text{'right_sysinfoheader'},
		    'open' => 0,
		    'table' => \@table });
	}

# Virtualmin licence
my %vserial;
if (&read_env_file($virtualmin_license_file, \%vserial) &&
    $vserial{'SerialNumber'} ne 'GPL') {
	my @table;
	my $open = 0;

	# Serial and key
	push(@table, { 'desc' => $text{'right_vserial'},
		       'value' => $vserial{'SerialNumber'} });
	push(@table, { 'desc' => $text{'right_vkey'},
		       'value' => $vserial{'LicenseKey'} });

	# Allowed domain counts
	my ($dleft, $dreason, $dmax, $dhide) =
		&count_domains("realdoms");
	push(@table, { 'desc' => $text{'right_vmax'},
		       'value' => $dmax <= 0 ? $text{'right_vunlimited'}
					     : $dmax });
	push(@table, { 'desc' => $text{'right_vleft'},
		       'value' => $dleft < 0 ? $text{'right_vunlimited'}
					     : $dleft });

	# Add allowed system counts
	my %lstatus;
	&read_file($licence_status, \%lstatus);
	if ($lstatus{'used_servers'}) {
		push(@table, { 'desc' => $text{'right_smax'},
			       'value' => $lstatus{'servers'} ||
					  $text{'right_vunlimited'} });
		push(@table, { 'desc' => $text{'right_sused'},
			       'value' => $lstatus{'used_servers'} });
		}

	# Show license expiry date
	if ($lstatus{'expiry'} =~ /^203[2-8]-/) {
		push(@table, { 'desc' => $text{'right_expiry'},
			       'value' => $text{'right_expirynever'} });
		}
	elsif ($lstatus{'expiry'}) {
		push(@table, { 'desc' => $text{'right_expiry'},
			       'value' => $lstatus{'expiry'} });
		my $ltm = &parse_license_date($lstatus{'expiry'});
		if ($ltm) {
			my $days = int(($ltm - time()) / (24*60*60));
			push(@table, { 'desc' => $text{'right_expirydays'},
				       'value' => $days < 0 ?
					&text('right_expiryago', -$days) :
					$days });
			$open = 1 if ($days < 7);
			}
		}

	push(@rv, { 'type' => 'table',
		    'id' => 'serial',
		    'desc' => $text{'right_licenceheader'},
		    'open' => $open,
		    'table' => \@table });

	# Re-check licence link
	push(@rv, { 'type' => 'link',
		    'priority' => 20,
		    'desc' => $text{'right_vlcheck'},
		    'link' => '/'.$module_name.'/licence.cgi' });
	}

# Documentation links
my $doclink = &get_virtualmin_docs();
push(@rv, { 'type' => 'link',
	    'priority' => 50,
	    'desc' => $text{'right_virtdocs'},
	    'target' => 'new',
	    'link' => $doclink });
if ($config{'docs_link'}) {
	push(@rv, { 'type' => 'link',
		    'priority' => 49,
		    'desc' => $text{'right_virtdocs2'},
		    'target' => 'new',
		    'link' => $config{'docs_link'} });
	}

return @rv;
}

sub get_virtualmin_docs
{               
return &master_admin() ?
		"http://www.virtualmin.com/documentation" :
       &reseller_admin() ?
		"http://www.virtualmin.com/documentation/users/reseller" :
       		"http://www.virtualmin.com/documentation/users/server-owner";
}      

1;