
our (%in, %config);

# script_wordpress_desc()
sub script_wordpress_desc
{
return "WordPress";
}

sub script_wordpress_uses
{
return ( "php" );
}

sub script_wordpress_longdesc
{
return "A semantic personal publishing platform with a focus on aesthetics, web standards, and usability";
}

# script_wordpress_versions()
sub script_wordpress_versions
{
return ( "6.5.2" );
}

sub script_wordpress_category
{
return ("Blog", "CMS");
}

sub script_wordpress_php_vers
{
return ( 5 );
}

sub script_wordpress_testable
{
return 1;
}

sub script_wordpress_php_modules
{
return ( "mysql", "gd", "json", "xml" );
}

sub script_wordpress_php_optional_modules
{
return ( "curl", "ssh2", "pecl-ssh2", "date",
         "hash", "imagick", "pecl-imagick", 
         "iconv", "mbstring", "openssl",
         "posix", "sockets", "tokenizer" );
}

sub script_wordpress_php_vars
{
return ([ 'memory_limit', '128M', '+' ],
        [ 'max_execution_time', 60, '+' ],
        [ 'file_uploads', 'On' ],
        [ 'upload_max_filesize', '10M', '+' ],
        [ 'post_max_size', '10M', '+' ] );
}

sub script_wordpress_dbs
{
return ( "mysql" );
}

sub script_wordpress_release
{
return 8;	# Fix regex for passmode
}

sub script_wordpress_php_fullver
{
my ($d, $ver, $sinfo) = @_;
if (&compare_versions($ver, "6.3") >= 0) {
	return "7.0.0";
	}
else {
	return "5.6.20";
	}
}

# script_wordpress_params(&domain, version, &upgrade-info)
# Returns HTML for table rows for options for installing Wordpress
sub script_wordpress_params
{
my ($d, $ver, $upgrade) = @_;
my $rv;
my $hdir = public_html_dir($d, 1);
if ($upgrade) {
	# Options are fixed when upgrading
	my ($dbtype, $dbname) = split(/_/, $upgrade->{'opts'}->{'db'}, 2);
	$rv .= ui_table_row("Database for WordPress tables", $dbname);
	my $dir = $upgrade->{'opts'}->{'dir'};
	$dir =~ s/^$d->{'home'}\///;
	$rv .= ui_table_row("Install directory", $dir);
	}
else {
	# Show editable install options
	my @dbs = domain_databases($d, [ "mysql" ]);
	$rv .= ui_table_row("Database for WordPress tables",
		     ui_database_select("db", undef, \@dbs, $d, "wordpress"));
	$rv .= ui_table_row("WordPress table prefix",
		     ui_textbox("dbtbpref", "wp_", 20));
	$rv .= ui_table_row("Install sub-directory under <tt>$hdir</tt>",
			   ui_opt_textbox("dir", &substitute_scriptname_template("wordpress", $d), 30, "At top level"));
	$rv .= ui_table_row("WordPress site name",
		ui_textbox("title", $d->{'owner'} || "My Blog", 25).
			   "&nbsp;".ui_checkbox("noauto", 1, "Do not perform initial setup", 0,
			   	"onchange=\"form.title.disabled=this.checked;document.getElementById('title_row').nextElementSibling.style.visibility=(this.checked?'hidden':'visible')\""), undef, undef, ["id='title_row'"]);
	}
return $rv;
}

# script_wordpress_parse(&domain, version, &in, &upgrade-info)
# Returns either a hash ref of parsed options, or an error string
sub script_wordpress_parse
{
my ($d, $ver, $in, $upgrade) = @_;
if ($upgrade) {
	# Options are always the same
	return $upgrade->{'opts'};
	}
else {
	my $hdir = public_html_dir($d, 0);
	$in{'dir_def'} || $in{'dir'} =~ /\S/ && $in{'dir'} !~ /\.\./ ||
		return "Missing or invalid installation directory";
	(!$in{'title'} && !$in->{'noauto'}) && return "Missing or invalid WordPress site name";
	$in{'passmodepass'} =~ /['"\\]/ && return "WordPress password cannot contain single quotes, double quotes, or backslashes";
	my $dir = $in{'dir_def'} ? $hdir : "$hdir/$in{'dir'}";
	my ($newdb) = ($in->{'db'} =~ s/^\*//);
	return { 'db' => $in->{'db'},
		 'newdb' => $newdb,
		 'dir' => $dir,
		 'noauto' => $in->{'noauto'},
		 'dbtbpref' => $in->{'dbtbpref'},
		 'path' => $in{'dir_def'} ? "/" : "/$in{'dir'}",
		 'title' => $in{'title'} };
	}
}

# script_wordpress_check(&domain, version, &opts, &upgrade-info)
# Returns an error message if a required option is missing or invalid
sub script_wordpress_check
{
local ($d, $ver, $opts, $upgrade) = @_;
$opts->{'dir'} =~ /^\// || return "Missing or invalid install directory";
$opts->{'db'} || return "Missing database";
if (-r "$opts->{'dir'}/wp-login.php") {
	return "WordPress appears to be already installed in the selected directory";
	}
$opts->{'dbtbpref'} =~ s/^\s+|\s+$//g;
$opts->{'dbtbpref'} = 'wp_' if (!$opts->{'dbtbpref'});
$opts->{'dbtbpref'} =~ /^\w+$/ || return "Database table prefix either not set or contains invalid characters";
$opts->{'dbtbpref'} .= "_" if($opts->{'dbtbpref'} !~ /_$/);
my ($dbtype, $dbname) = split(/_/, $opts->{'db'}, 2);
my $clash = find_database_table($dbtype, $dbname, "$opts->{'dbtbpref'}.*");
$clash && return "WordPress appears to be already using \"$opts->{'dbtbpref'}\" database table prefix";
return undef;
}

# script_wordpress_files(&domain, version, &opts, &upgrade-info)
# Returns a list of files needed by Wordpress, each of which is a hash ref
# containing a name, filename and URL
sub script_wordpress_files
{
my ($d, $ver, $opts, $upgrade) = @_;
return (
	{ 'name' => "cli",
	   'file' => "wordpress-cli.phar",
	   'url' => "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar",
	   'nocache' => 1 } );
}

sub script_wordpress_commands
{
return ("unzip");
}

# script_wordpress_install(&domain, version, &opts, &files, &upgrade-info)
# Actually installs WordPress, and returns either 1 and an informational
# message, or 0 and an error
sub script_wordpress_install
{
local ($d, $version, $opts, $files, $upgrade, $domuser, $dompass) = @_;
my ($out, $ex);
if ($opts->{'newdb'} && !$upgrade) {
        my $err = create_script_database($d, $opts->{'db'});
        return (0, "Database creation failed : $err") if ($err);
        }
my ($dbtype, $dbname) = split(/_/, $opts->{'db'}, 2);
my $dbuser = $dbtype eq "mysql" ? mysql_user($d) : postgres_user($d);
my $dbpass = $dbtype eq "mysql" ? mysql_pass($d) : postgres_pass($d, 1);
my $dbphptype = $dbtype eq "mysql" ? "mysql" : "psql";
my $dbhost = get_database_host($dbtype, $d);
my $dberr = check_script_db_connection(
	$d, $dbtype, $dbname, $dbuser, $dbpass);
my $d_proto = domain_has_ssl($d) ? "https://" : "http://";
my $url = script_path_url($d, $opts);
return (0, "Database connection failed : $dberr") if ($dberr);

my $dom_php_bin = &get_php_cli_command($opts->{'phpver'}) || &has_command("php");
my $wp = "cd $opts->{'dir'} && $dom_php_bin $opts->{'dir'}/wp-cli.phar";

# Copy wordpress-cli
&make_dir_as_domain_user($d, $opts->{'dir'}, 0755) if (!-d $opts->{'dir'});
&copy_source_dest($files->{'cli'}, "$opts->{'dir'}/wp-cli.phar");
&set_permissions_as_domain_user($d, 0750, "$opts->{'dir'}/wp-cli.phar");

# Install using cli
if (!$upgrade) {
	my $err_continue = "<br>Installation can be continued manually at <a target=_blank href='${url}wp-admin'>$url</a>.";

	# Start installation
	my $out = &run_as_domain_user($d, "$wp core download --version=$version 2>&1");
	if ($? && $out !~ /Success:\s+WordPress\s+downloaded/i) {
		return (-1, "\`wp core download\` failed` : $out");
		}

	if (!$opts->{'noauto'}) {
		# Configure the database
		$out = &run_as_domain_user($d,
			"$wp config create --dbname=".quotemeta($dbname).
			" --dbprefix=".quotemeta($opts->{'dbtbpref'}).
			" --dbuser=".quotemeta($dbuser)." --dbpass=".quotemeta($dbpass).
			" --dbhost=".quotemeta($dbhost)." 2>&1");
		if ($?) {
			return (-1, "\`wp config create\` failed : $out$err_continue");
			}

		# Set db prefix, if given
		if ($opts->{'dbtbpref'}) {
			my $out = &run_as_domain_user($d,
				"$wp config set table_prefix ".
				quotemeta($opts->{'dbtbpref'}).
				" --type=variable".
				" --path=".$opts->{'dir'}." 2>&1");
			if ($?) {
				return (-1, "\`wp config set table_prefix\` failed : $out$err_continue");
				}
			}
		
		# Do the install
		$out = &run_as_domain_user($d,
			"$wp core install " .
			" --url=$d_proto".quotemeta("$d->{'dom'}$opts->{'path'}").
			" --title=".quotemeta($opts->{'title'} || $d->{'owner'}).
			" --admin_user=".quotemeta($domuser).
			" --admin_password=".quotemeta($dompass).
			" --admin_email=".quotemeta($d->{'emailto'})." 2>&1");
		if ($?) {
			return (-1, "\`wp core install\` failed : $out$err_continue");
			}

		# Force update site URL manually as suggested by the installer
		# Update `siteurl` option
		$out = &run_as_domain_user($d,
			"$wp option update siteurl \"$d_proto".quotemeta("$d->{'dom'}$opts->{'path'}")."\" 2>&1");
		if ($?) {
			return (-1, "\`wp option update siteurl\` failed : $out");
			}
		# Update `home` option
		$out = &run_as_domain_user($d,
			"$wp option update home \"$d_proto".quotemeta("$d->{'dom'}$opts->{'path'}")."\" 2>&1");
		if ($?) {
			return (-1, "\`wp option update home\` failed : $out");
			}
		# Update user `user_url` record
		$out = &run_as_domain_user($d,
			"$wp user update ".quotemeta($domuser)." --user_url=\"$d_proto".quotemeta("$d->{'dom'}$opts->{'path'}")."\" 2>&1");
		if ($?) {
			return (-1, "\`wp user update\` failed : $out");
			}
		}
	# Clean up an index.html file that might take precendence over index.php
	my $hfile = $opts->{'dir'}."/index.html";
	if (-r $hfile) {
		&unlink_file_as_domain_user($d, $hfile);
		}
	
	# Add webserver records
	&script_wordpress_webserver_add_records($d, $opts);
	}
else {
	# Do the upgrade
	my $out = &run_as_domain_user($d,
                    "$wp core upgrade --version=$version 2>&1");
	if ($?) {
		return (-1, "\`wp core upgrade\` failed : $out");
		}
	}

# Delet edefault config
if (!$opts->{'noauto'} || $upgrade) {
	unlink_file("$opts->{'dir'}/wp-config-sample.php");
	}

# Install is all done, return the base URL
my $rp = $opts->{'dir'};
$rp =~ s/^$d->{'home'}\///;
my $msg_type = $upgrade ? "upgrade" : "installation";
my $access_msg = $upgrade || !$opts->{'noauto'} ? "It can be accessed" : "It can be configured";
my $dbcreds = $upgrade ? "" : 
	!$opts->{'noauto'} ? "" : "<br>For database credentials, use '<tt>$dbuser</tt>' for the user, '<tt>$dbpass</tt>' for the password, and '<tt>$dbname</tt>' for the database name.";
return (1, "WordPress $msg_type completed. $access_msg at <a target=_blank href='${url}wp-admin'>$url</a>$dbcreds", "Under $rp using $dbphptype database $dbname", $url, !$opts->{'noauto'} ? $domuser : undef, !$opts->{'noauto'} ? $dompass : undef);
}

# script_wordpress_uninstall(&domain, version, &opts)
# Un-installs a Wordpress installation, by deleting the directory and database.
# Returns 1 on success and a message, or 0 on failure and an error
sub script_wordpress_uninstall
{
my ($d, $version, $opts) = @_;

# Remove the contents of the target directory
my $derr = delete_script_install_directory($d, $opts);
return (0, $derr) if ($derr);

# Remove all wp_ tables from the database
cleanup_script_database($d, $opts->{'db'}, $opts->{'dbtbpref'});

# Take out the DB
if ($opts->{'newdb'}) {
        delete_script_database($d, $opts->{'db'});
        }

# Remove the webserver records
&script_wordpress_webserver_delete_records($d, $opts);

return (1, "WordPress directory and tables deleted.");
}

# script_wordpress_db_conn_desc()
# Returns a list of options for config file to update
sub script_wordpress_db_conn_desc
{
my $db_conn_desc = 
    { 'wp-config.php' => 
        {
           'dbpass' => 
           {
               'replace' => [ 'define\(\s*[\'"]DB_PASSWORD[\'"],' =>
                              'define(\'DB_PASSWORD\', \'$$sdbpass\');' ],
               'func' => 'php_quotemeta',
               'func_params' => 1,
           },
           'dbuser' => 
           {
               'replace' => [ 'define\(\s*[\'"]DB_USER[\'"],' => "define('DB_USER', '\$\$sdbuser');" ],
           },
           'dbhost' => 
           {
               'replace' => [ 'define\(\s*[\'"]DB_HOST[\'"],' => "define('DB_HOST', '\$\$sdbhost');" ],
           },
           'dbname' => 
           {
               'replace' => [ 'define\(\s*[\'"]DB_NAME[\'"],' => "define('DB_NAME', '\$\$sdbname');" ],
           },
        }
    };
return $db_conn_desc;
}

# script_wordpress_realversion(&domain, &opts)
# Returns the real version number of some script install, or undef if unknown
sub script_wordpress_realversion
{
my ($d, $opts, $sinfo) = @_;
my $lref = read_file_lines("$opts->{'dir'}/wp-includes/version.php", 1);
foreach my $l (@$lref) {
	if ($l =~ /wp_version\s*=\s*'([0-9\.]+)'/) {
		return $1;
		}
	}
return undef;
}

# script_wordpress_latest(version)
# Returns a URL and regular expression or callback func to get the version
sub script_wordpress_latest
{
my ($ver) = @_;
return ( "http://wordpress.org/download/",
	 "Download\\s+WordPress\\s+([0-9\\.]+)" );
}

sub script_wordpress_site
{
return 'http://wordpress.org/';
}

sub script_wordpress_gpl
{
return 1;
}

sub script_wordpress_required_quota
{
return (128, 'M') ;
}

sub script_wordpress_passmode
{
return (1, 8, '^(?=.*[A-Z])(?=.*[a-z])(?=.*\d).{8,}$');
}

sub script_wordpress_webserver_add_records
{
my ($d, $opts) = @_;
# Add Nginx webserver records for permalinks to work
if (&domain_has_website($d) eq 'virtualmin-nginx' &&
    &indexof('virtualmin-nginx', @plugins) >= 0) {
	
	my $locdir = $opts->{'path'};
	$locdir =~ s/\/$//;
	$locdir ||= '/';
	my $locdirarg = $locdir;
	$locdirarg .= '/' if ($locdirarg !~ /\/$/);
	&virtualmin_nginx::lock_all_config_files();
	my $server = &virtualmin_nginx::find_domain_server($d);
	if ($server) {
		my @locs = &virtualmin_nginx::find("location", $server);
		my ($loc) = grep {
			if ($locdir eq '/') {
				$_->{'words'}->[0] eq $locdir
				}
			else {
				$_->{'words'}->[0] =~ /\Q$locdir\E$/ 
				}	
		} @locs;
		# We already have a location for this directory
		if ($loc) {
			my $locold = $loc;
			my ($contains_try_files) =
					grep { $_->{name} eq 'try_files' &&
					       $_->{'words'}->[0] eq '$uri' &&
					       $_->{'words'}->[1] eq '$uri/' &&
					       $_->{'words'}->[2] eq ($locdirarg.'index.php?$args') }
							@{$loc->{members}};
			if ($contains_try_files) {
				# Exact record already exists
				&virtualmin_nginx::unlock_all_config_files();
				return;
				}
			else {
				# Add try_files to existing location
				push(@{$loc->{'members'}},
					{ 'name' => 'try_files',
					  'words' => [ '$uri',
					               '$uri/',
					               ($locdirarg.'index.php?$args') ]});
				&virtualmin_nginx::save_directive($server, [ $locold ], [ $loc ]);
				}
			}
		else {
			# Add a new location for installed directory
			$loc = {
				'name' => 'location',
				'words' => [ $locdir ],
				'type' => 1,
				'members' => [
					{ 'name' => 'try_files',
					  'words' => [ '$uri',
						       '$uri/',
						       ($locdirarg.'index.php?$args') ]}]};
			&virtualmin_nginx::save_directive($server, [ ], [ $loc ]);
			}
		&virtualmin_nginx::flush_config_file_lines();
		&virtualmin_nginx::unlock_all_config_files();
		&register_post_action(\&virtualmin_nginx::print_apply_nginx);
		}
	}
}

sub script_wordpress_webserver_delete_records
{
my ($d, $opts) = @_;
# Remove Nginx webserver previously added records
if (&domain_has_website($d) eq 'virtualmin-nginx' &&
    &indexof('virtualmin-nginx', @plugins) >= 0) {
	my $locdir = $opts->{'path'};
	$locdir =~ s/\/$//;
	$locdir ||= '/';
	my $locdirarg = $locdir;
	$locdirarg .= '/' if ($locdirarg !~ /\/$/);
	&virtualmin_nginx::lock_all_config_files();
	my $server = &virtualmin_nginx::find_domain_server($d);
	if ($server) {
		my @locs = &virtualmin_nginx::find("location", $server);
		my ($loc) = grep {
			if ($locdir eq '/') {
				$_->{'words'}->[0] eq $locdir
				}
			else {
				$_->{'words'}->[0] =~ /\Q$locdir\E$/ 
				}	
		} @locs;
		# Found location directive for this directory
		if ($loc) {
			my $locold = $loc;
			my ($contains_try_files) =
					grep { $_->{name} eq 'try_files' &&
					       $_->{'words'}->[0] eq '$uri' &&
					       $_->{'words'}->[1] eq '$uri/' &&
					       $_->{'words'}->[2] eq ($locdirarg.'index.php?$args') }
							@{$loc->{members}};
			# If exact record exists alone remove the
			# location, otherwise remove record alone
			my $directives_to_remove =
				(grep { $_ ne $contains_try_files } @{$loc->{members}}) ?
					$contains_try_files : $loc;
			if ($directives_to_remove) {
				&virtualmin_nginx::save_directive($server, [ $directives_to_remove ], [ ]);
				&virtualmin_nginx::flush_config_file_lines();
				&register_post_action(\&virtualmin_nginx::print_apply_nginx);
				}
			&virtualmin_nginx::unlock_all_config_files();
			}
		}
	}
}

# script_wordpress_kit(&domain, &script, &opts)
# Called after a script is installed, to enable any extra actions needed
sub script_wordpress_kit
{
my ($d, $script, $sinfo) = @_;
my $opts = $sinfo->{'opts'};
my $php = &get_php_cli_command($opts->{'phpver'}) || &has_command("php");
my $wp_cli = "$php $opts->{'dir'}/wp-cli.phar --path=$opts->{'dir'}";
my $_t = 'scripts_kit_wp_';

# Has to be called using eval for maximum speed (avg 
# expected load time is + 0.5s to default page load)
my $wp_cli_command = $wp_cli . ' eval \'echo json_encode([
    "wp_debug" => defined("WP_DEBUG") ? WP_DEBUG : 0, 
    "wp_debug_display" => defined("WP_DEBUG_DISPLAY") ? WP_DEBUG_DISPLAY : 0, 
    "wp_debug_log" => defined("WP_DEBUG_LOG") ? str_replace("'.$opts->{'dir'}.'", "", WP_DEBUG_LOG) : 0, 
    "wp_memory_limit" => defined("WP_MEMORY_LIMIT") ? WP_MEMORY_LIMIT : 0, 
    "wp_max_memory_limit" => defined("WP_MAX_MEMORY_LIMIT") ? WP_MAX_MEMORY_LIMIT : 0, 
    "disallow_file_edit" => defined("DISALLOW_FILE_EDIT") ? DISALLOW_FILE_EDIT : 0, 
    "concatenate_scripts" => defined("CONCATENATE_SCRIPTS") ? (CONCATENATE_SCRIPTS == false ? 0 : 1) : 1, 
    "wp_auto_update_core" => defined("WP_AUTO_UPDATE_CORE") ? (WP_AUTO_UPDATE_CORE == true ? 2 : (WP_AUTO_UPDATE_CORE == "minor" ? 1 : 0)) : (defined("WP_DEBUG") ? (WP_DEBUG == true ? 2 : 1) : 1),
    "automatic_updater_disabled" => defined("AUTOMATIC_UPDATER_DISABLED") ? AUTOMATIC_UPDATER_DISABLED : 0, 
    "blogname" => get_option("blogname"), 
    "blog_public" => get_option("blog_public"), 
    "default_pingback_flag" => get_option("default_pingback_flag"), 
    "default_ping_status" => get_option("default_ping_status"), 
    "maintenance_mode" => get_option("maintenance_mode"), 
    "admin_email" => get_option("admin_email"),
    "version" => get_bloginfo("version"),
    "description" => get_bloginfo("description"),
    "wpurl" => get_bloginfo("wpurl"),
    "url" => get_bloginfo("url"),
    "language" => get_bloginfo("language"),
    "plugins" => array_map(function($plugin) {
        require_once(ABSPATH . "wp-admin/includes/plugin.php");
        require_once(ABSPATH . "wp-admin/includes/update.php");
        $data = get_plugin_data(WP_PLUGIN_DIR . "/" . $plugin);
        $update = get_site_transient("update_plugins");
        return [
            "name" => $data["Name"],
            "version" => $data["Version"],
            "new_version" => isset($update->response[$plugin]) ? $update->response[$plugin]->new_version : 0
        ];
    }, array_keys(get_plugins())),
    "themes" => array_map(function($theme) {
        require_once(ABSPATH . "wp-admin/includes/theme.php");
        require_once(ABSPATH . "wp-admin/includes/update.php");
        $theme_data = wp_get_theme($theme);
        $update = get_site_transient("update_themes");
        return [
            "name" => $theme_data->get("Name"),
            "version" => $theme_data->get("Version"),
            "new_version" => isset($update->response[$theme]) ? $update->response[$theme]->new_version : 0
        ];
    }, array_keys(wp_get_themes()))
]);\'';
my $wp = &run_as_domain_user($d, "$wp_cli_command 2>&1");
eval { $wp = &convert_from_json($wp); };
if ($@) {
	&error_stderr("Failed to parse JSON output from WP-CLI command : $@");
	my $err = " : $@";
	$err = " : $wp" if ($wp);
	return "<pre>$err</pre>";
	}

# Setttings tab
my $settings_tab_content;
# Site URL
push(@$settings_tab_content, {
	desc  => $text{"${_t}url"},
	value => &ui_opt_textbox(
	    "kit_url", undef, 35, $wp->{'url'} . "<br>",
	    $text{'edit_set'})});
# Home
push(@$settings_tab_content, {
	desc  => $text{"${_t}wpurl"},
	value => &ui_opt_textbox(
	    "kit_wpurl", undef, 35, $wp->{'wpurl'} . "<br>",
	    $text{'edit_set'})});
# Admin email
push(@$settings_tab_content, {
	desc  => $text{"${_t}admin_email"},
	value => &ui_opt_textbox(
	    "kit_admin_email", undef, 30, $wp->{'admin_email'} . "<br>",
	    $text{'edit_set'})});
# Set password
push(@$settings_tab_content, {
	desc  => $text{"${_t}admin_pass"},
	value => &ui_opt_textbox(
	    "kit_admin_password", undef, 20, $text{'user_passdef'},
	    $text{'edit_set'})});
# Site name
push(@$settings_tab_content, {
	desc  => $text{"${_t}blogname"},
	value => &ui_opt_textbox(
	    "kit_blogname", undef, 25, $wp->{'blogname'} . "<br>",
	    $text{'edit_set'})});
# Site description
if ($wp->{'description'}) {
	push(@$settings_tab_content, {
		desc  => $text{"${_t}description"},
		value => &ui_opt_textbox(
		"kit_description", undef, 35, $wp->{'description'} . "<br>",
		$text{'edit_set'}) });
	}
# Debug mode
push(@$settings_tab_content, {
	desc  => $text{"${_t}debug"},
	value => &ui_radio(
	    "kit_wp_debug",
	    $wp->{'wp_debug'} ? ($wp->{'wp_debug_log'} ? 2 : 1) : 0,
		[ [ 0, $text{"${_t}debug0"} . "<br>" ],
		  [ 1, $text{"${_t}debug1"} . "<br>" ],
		  [ 2, $text{"${_t}debug2"} ] ] )});
# Maintenance mode
push(@$settings_tab_content, {
	desc  => $text{"${_t}maintenance_mode"},
	value => &ui_yesno_radio(
	    "kit_maintenance_mode", $wp->{'maintenance_mode'} ? 1 : 0)});
# Site visibility
push(@$settings_tab_content, {
	desc  => $text{"${_t}blog_public"},
	value => &ui_yesno_radio(
	    "kit_blog_public", $wp->{'blog_public'} ? 1 : 0)});
# Pingbacks
push(@$settings_tab_content, {
	desc  => $text{"${_t}default_pingback_flag"},
	value => &ui_yesno_radio(
	    "kit_default_pingback_flag",
	    	$wp->{'default_pingback_flag'} ? 1 : 0)});
# Trackbacks
push(@$settings_tab_content, {
	desc  => $text{"${_t}default_ping_status"},
	value => &ui_yesno_radio(
	    "kit_default_ping_status",
	    	$wp->{'default_ping_status'} eq 'open' ? 1 : 0)});
# File editing
push(@$settings_tab_content, {
	desc  => $text{"${_t}disallow_file_edit"},
	value => &ui_yesno_radio(
	    "kit_disallow_file_edit", $wp->{'disallow_file_edit'} ? 1 : 0)});
# Script concatenation
push(@$settings_tab_content, {
	desc  => $text{"${_t}concatenate_scripts"},
	value => &ui_yesno_radio(
	    "kit_concatenate_scripts", $wp->{'concatenate_scripts'} ? 1 : 0)});
# Memory limit
push(@$settings_tab_content, {
	desc  => $text{"${_t}memory_limit"},
	value => &ui_opt_textbox(
	    "kit_memory_limit", undef, 6,
	    	"$text{\"${_t}memory_limit_upto\"} $wp->{'wp_memory_limit'}",
		$text{'edit_set'})});

# XXX: Add more tabs

# Tabs
my @tabs = (
	[ "settings", 'Settings' ],
	[ "plugins_and_themes", 'Plugin and Themes' ],
	[ "clone", 'Clone' ],
	[ "backup", 'Backup and Restore' ] );

my $data = &ui_tabs_start(\@tabs, "tab", "settings", 0);

$data .= &ui_tabs_start_tab("tab", "settings");
$data .= &ui_table_start(undef, "width=100%", 2);
foreach my $option (@$settings_tab_content) {
	$data .= &ui_table_row($option->{'desc'}, $option->{'value'});
	}
$data .= &ui_table_end();
$data .= &ui_tabs_end_tab();

$data .= &ui_tabs_start_tab("tab", "clone");
$data .= "";
$data .= &ui_tabs_end_tab();

$data .= &ui_tabs_start_tab("tab", "plugins_and_themes");
$data .= "";
$data .= &ui_tabs_end_tab();

$data .= &ui_tabs_start_tab("tab", "backup");
$data .= "";
$data .= &ui_tabs_end_tab();

$data .= &ui_tabs_end();

return $data;
}

1;
