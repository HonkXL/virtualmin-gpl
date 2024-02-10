# Functions for talking to Amazon's S3 service

@s3_perl_modules = ( "S3::AWSAuthConnection", "S3::QueryStringAuthGenerator" );
$s3_groups_uri = "http://acs.amazonaws.com/groups/global/";

# check_s3()
# Returns an error message if S3 cannot be used, or undef if OK. Also returns
# a second more detailed warning if needed.
sub check_s3
{
# Return no error if `aws_cmd` is set and installed
if (&has_aws_cmd()) {
	my $defs3 = &get_default_s3_account();
	my ($ok, $err) = &can_use_aws_s3_cmd(
		$defs3 ? ( $defs3->{'access'}, $defs3->{'secret'} ) : ( ));
	if (!$ok) {
		return (undef, &text('s3_eawscmd',
				"<tt>".&html_escape($err)."</tt>"));
		}
	}

# Check for core S3 modules
my ($err, $warn);
foreach my $m ("XML::Simple", "Digest::HMAC_SHA1",
               "LWP::Protocol::https", @s3_perl_modules) {
	eval "use $m";
	if ($@ =~ /Can't locate/) {
		$err = &text('s3_emodule', "<tt>$m</tt>");
		$err .= " ".&vui_install_mod_perl_link(
			$m, "list_buckets.cgi", $text{'index_buckets'});
		}
	elsif ($@) {
		$err = &text('s3_emodule2', "<tt>$m</tt>", "$@");
		}
	}

if (!$err) {
	# Check for SSL modules
	eval "use Crypt::SSLeay";
	if ($@) {
		eval "use Net::SSLeay";
		}
	if ($@) {
		$err = &text('s3_emodule3', "<tt>Crypt::SSLeay</tt>",
					    "<tt>Net::SSLeay</tt>");
		$err .= " ".&vui_install_mod_perl_link(
		    'Net::SSLeay', "list_buckets.cgi", $text{'index_buckets'});
		}
	}

# Offer to install the aws command, even if other dependencies are available
if (!&has_aws_cmd()) {
	$warn = $text{'cloud_s3_noawscli'};
	if (&foreign_available("software")) {
		$warn .= " ".&text('cloud_s3_noawscli_install',
				  'install_awscli.cgi');
		}
	}

return ($err, $warn);
}

# require_s3()
# Load Perl modules needed by S3 (which are included in Virtualmin)
sub require_s3
{
foreach my $m (@s3_perl_modules) {
	eval "use $m";
	die "$@" if ($@);
	}
}

# init_s3_bucket(access-key, secret-key, bucket, attempts, [location])
# Connect to S3 and create a bucket (if needed). Returns undef on success or
# an error message on failure.
sub init_s3_bucket
{
&require_s3();
my ($akey, $skey, $bucket, $tries, $location) = @_;
my $s3 = &get_s3_account($akey);
$location ||= $s3->{'location'} if ($s3);
if (&can_use_aws_s3_cmd($akey, $skey)) {
	return &init_s3_bucket_aws_cmd(@_);
	}
$tries ||= 1;
my $err;
my $data;
if ($location) {
	$data = "<CreateBucketConfiguration>".
		"<LocationConstraint>".
		$location.
		"</LocationConstraint>".
		"</CreateBucketConfiguration>";
	}
for(my $i=0; $i<$tries; $i++) {
	$err = undef;
	my $conn = &make_s3_connection($akey, $skey);
	if (!$conn) {
		$err = $text{'s3_econn'};
		sleep(10*($i+1));
		next;
		}

	# Check if the bucket already exists, by trying to list it
	my $response = $conn->list_bucket($bucket);
	if ($response->http_response->code == 200) {
		last;
		}

	# Try to fetch my buckets
	my $response = $conn->list_all_my_buckets();
	if ($response->http_response->code != 200) {
		$err = &text('s3_elist', &extract_s3_message($response));
		sleep(10*($i+1));
		next;
		}

	# Re-open the connection, as sometimes it times out
	$conn = &make_s3_connection($akey, $skey);

	# Check if given bucket is in the list
	my ($got) = grep { $_->{'Name'} eq $bucket } @{$response->entries};
	if (!$got) {
		# Create the bucket
		$response = $conn->create_bucket($bucket, undef, $data);
		if ($response->http_response->code != 200) {
			$err = &text('s3_ecreate',
				     &extract_s3_message($response));
			sleep(10*($i+1));
			next;
			}
		}
	last;
	}
return $err;
}

# init_s3_bucket_aws_cmd(access-key, secret-key, bucket, attempts, [location])
# Like init_s3_bucket, but shells out to the awe command
sub init_s3_bucket_aws_cmd
{
my ($akey, $skey, $bucket, $tries, $location) = @_;
my @regionflag = $location ? ( "--region", $location ) : ( );
$tries ||= 1;
my $err;
for(my $i=0; $i<$tries; $i++) {
	$err = undef;

	# Check if bucket already exists
	my $buckets = &s3_list_buckets($akey, $skey);
	if (!ref($buckets)) {
		$err = $buckets;
		sleep(10*($i+1));
		next;
		}
	my ($got) = grep { $_->{'Name'} eq $bucket } @$buckets;
	last if ($got);

	# If not, create it in the chosen region
	my $out = &call_aws_s3_cmd($akey,
                [ @regionflag, "mb", "s3://$bucket" ]);
	if ($?) {
		$err = $out;
		sleep(10*($i+1));
		next;
		}
	else {
		last;
		}
	}
return $err;
}

sub extract_s3_message
{
my ($response) = @_;
if ($response->body() =~ /<Message>(.*)<\/Message>/i) {
	return $1;
	}
elsif ($response->http_response->code) {
	return "HTTP status ".$response->http_response->code;
	}
return undef;
}

# s3_upload(access-key, secret-key, bucket, source-file, dest-filename, [&info],
#           [&domains], attempts, [reduced-redundancy], [multipart])
# Upload some file to S3, and return undef on success or an error message on
# failure. Unfortunately we cannot simply use S3's put method, as it takes
# a scalar for the content, which could be huge.
sub s3_upload
{
my ($akey, $skey, $bucket, $sourcefile, $destfile, $info, $dom, $tries,
       $rrs, $multipart) = @_;
$tries ||= 1;
my @st = stat($sourcefile);
@st || return "File $sourcefile does not exist";
if (&can_use_aws_s3_cmd($akey, $skey)) {
	return &s3_upload_aws_cmd(@_);
	}
&require_s3();
my $headers = { };
if ($rrs) {
	$headers->{'x-amz-storage-class'} = 'REDUCED_REDUNDANCY';
	}
my $rrsheaders = { %$headers };
if ($st[7] >= 2**31) {
	# 2GB or more forces multipart mode
	$multipart = 1;
	}
if (!$multipart) {
	$headers->{'Content-Length'} = $st[7];
	}

my $err;
my $endpoint = undef;
my $noep_conn = &make_s3_connection($akey, $skey);
my $backoff = 2;
for(my $i=0; $i<$tries; $i++) {
	my $newendpoint;
	$err = undef;
	my $conn = &make_s3_connection($akey, $skey, $endpoint);
	if (!$conn) {
		$err = $text{'s3_econn'};
		next;
		}
	my $path = $endpoint ? $destfile : "$bucket/$destfile";
	my $authpath = "$bucket/$destfile";

	# Delete any .info or .dom file first, as it will no longer be valid.
	# Only needs to be done the first time.
	if (!$endpoint) {
		$noep_conn->delete($bucket, $destfile.".info");
		$noep_conn->delete($bucket, $destfile.".dom");
		}

	# Use the S3 library to create a request object, but use Webmin's HTTP
	# function to open it.
	my $req;
	if ($multipart) {
		$req = &s3_make_request($conn, $path."?uploads", "POST",
				"dummy", $headers, $authpath."?uploads");
		}
	else {
		$req = &s3_make_request($conn, $path, "PUT", "dummy",
				$headers, $authpath);
		}
	my ($host, $port, $page, $ssl) = &parse_http_url($req->uri);
	my $h = &make_http_connection(
		$host, $port, $ssl, $req->method, $page);
	if (!ref($h)) {
		$err = "HTTP connection to ${host}:${port} ".
		       "for $page failed : $h";
		next;
		}
	my $hinput;
	foreach my $hfn ($req->header_field_names) {
		&write_http_connection($h, $hfn.": ".$req->header($hfn)."\r\n");
		$hinput .= $hfn.": ".$req->header($hfn)."\r\n";
		}
	&write_http_connection($h, "\r\n");

	# Send the backup file contents
	my $writefailed;
	if (!$multipart) {
		local $SIG{'PIPE'} = 'IGNORE';
		my $buf;
		open(BACKUP, "<".$sourcefile);
		while(read(BACKUP, $buf, &get_buffer_size()) > 0) {
			if (!&write_http_connection($h, $buf)) {
				$writefailed = $!;
				last;
				}
			}
		close(BACKUP);
		}

	# Read back response .. this needs to be our own code, as S3 does
	# some wierd redirects
	my $line = &read_http_connection($h);
	$line =~ s/\r|\n//g;

	# Read the headers
	my %rheader;
	my $htext;
	while(1) {
		my $hline = &read_http_connection($h);
		$htext .= $hline;
		$hline =~ s/\r\n//g;
		$hline =~ /^(\S+):\s+(.*)$/ || last;
		$rheader{lc($1)} = $2;
		}

	# Read the body
	my $out;
	while(defined($buf = &read_http_connection($h, 1024))) {
		$out .= $buf;
		}
	&close_http_connection($h);

	if ($line !~ /\S/) {
		$err = "Empty response to HTTP request. Headers were : $htext";
		}
	elsif ($line =~ /^HTTP\/1\..\s+(503)(\s+|$)/) {
		# Backoff and retry without increasing the tries count
		sleep($backoff);
		$backoff *= 2;
		if ($backoff > 120) {
			$err = "Backed off up to limit of 120 seconds";
			}
		else {
			$i--;
			next;
			}
		}
	elsif ($line !~ /^HTTP\/1\..\s+(200|30[0-9])(\s+|$)/) {
		my ($out1) = split(/\r?\n/, $out);
		$err = "Invalid HTTP response : $line : $out1";
		}
	elsif ($1 >= 300 && $1 < 400) {
		# Follow the SOAP redirect
		if ($out =~ /<Endpoint>([^<]+)<\/Endpoint>/) {
			if ($endpoint ne $1) {
				$endpoint = $1;
				$err = "Redirected to $endpoint";
				$newendpoint = 1;
				$i--;	# Doesn't count as a try
				}
			else {
				$err = "Redirected to same endpoint $endpoint";
				}
			}
		else {
			$err = "Missing new endpoint in redirect : ".
				&html_escape($out);
			}
		}
	elsif ($writefailed) {
		$err = "HTTP transfer failed : $writefailed";
		}

	if (!$err && $multipart) {
		# Response should contain upload ID
		if ($out !~ /<UploadId>([^<]+)<\/UploadId>/i) {
			$err = $out;
			}
		else {
			# Multi-part upload started .. send the bits
			my $uploadid = $1;
			my $sent = 0;
			my $part = 1;
			my $j = 0;
			my @tags;
			my $chunksize = ($config{'s3_chunk'} || 5) * 1024*1024;
			while($sent < $st[7]) {
				my $chunk = $st[7] - $sent;
				$chunk = $chunksize if ($chunk > $chunksize);
				my ($pok, $ptag) = &s3_part_upload(
				    $conn, $bucket, $endpoint, $sourcefile,
				    $destfile, $part, $sent, $chunk, $uploadid);
				if (!$pok) {
					# This part failed
					if ($j++ > $tries) {
						# Too many failures
						$err = "Part $part failed at ".
						       "$sent : $ptag";
						last;
						}
					else {
						# Can re-try
						sleep($j+1);
						}
					}
				else {
					# Part worked, move on to the next one
					$part++;
					$sent += $chunk;
					push(@tags, $ptag);
					$j = 0;
					}
				}
			if (!$err) {
				# Complete the upload
				my $response = $noep_conn->complete_upload(
					$bucket, $destfile, $uploadid, \@tags);
				if ($response->http_response->code != 200) {
					$err = "Completion failed : ".
					       &extract_s3_message($response);
					}
				}
			else {
				# Abort the upload
				my $response = $noep_conn->abort_upload(
					$bucket, $destfile, $uploadid);
				if ($response->http_response->code < 200 ||
				    $response->http_response->code >= 300) {
					$err = "Abort failed : ".
					       &extract_s3_message($response).
					       "Original error : $err";
					}
				}
			}
		}

	if (!$err && $info) {
		# Write out the info file, if given
		my $iconn = &make_s3_connection($akey, $skey);
		my $response = $iconn->put($bucket, $destfile.".info",
					     &serialise_variable($info),
					     $rrsheaders);
		if ($response->http_response->code != 200) {
			$err = &text('s3_einfo',
                                     &extract_s3_message($response));
			}
		}
	if (!$err && $dom) {
		# Write out the .dom file, if given
		my $iconn = &make_s3_connection($akey, $skey);
		my $response = $iconn->put($bucket, $destfile.".dom",
		     &serialise_variable(&clean_domain_passwords($dom)),
		     $rrsheaders);
		if ($response->http_response->code != 200) {
			$err = &text('s3_edom',
                                     &extract_s3_message($response));
			}
		}
	if ($err) {
		# Wait a little before re-trying
		sleep(10*($i+1)) if (!$newendpoint);
		}
	else {
		# Worked .. end of the job
		last;
		}
	}

return $err;
}

# s3_upload_aws_cmd(access-key, secret-key, bucket, source-file, dest-filename,
# 		    [&info], [&domains], attempts, [reduced-redundancy],
# 		    [multipart])
# Has the same semantics as s3_upload, but uses the aws command instead of
# implementing the upload process itself
sub s3_upload_aws_cmd
{
my ($akey, $skey, $bucket, $sourcefile, $destfile, $info, $dom, $tries,
       $rrs, $multipart) = @_;
$tries ||= 1;
my $err;
my @rrsargs;
if($rrs) {
	push(@rrsargs, "--storage-class", "REDUCED_REDUNDANCY");
	}
my @regionflag = &s3_region_flag($akey, $skey, $bucket);
for(my $i=0; $i<$tries; $i++) {
	$err = undef;
	my $out = &call_aws_s3_cmd($akey,
		[ @regionflag,
		  "cp", $sourcefile, "s3://$bucket/$destfile", @rrsargs ]);
	if ($? || $out =~ /upload\s+failed/) {
		$err = $out;
		}
	if (!$err && $info) {
		# Upload the .info file
		my $temp = &uncat_transname(&serialise_variable($info));
		my $out = &call_aws_s3_cmd($akey,
		    [ @regionflag, 
		      "cp", $temp, "s3://$bucket/$destfile.info", @rrsargs ]);
		$err = $out if ($? || $out =~ /upload\s+failed/);
		}
	if (!$err && $dom) {
		# Upload the .dom file
		my $temp = &uncat_transname(&serialise_variable(
				&clean_domain_passwords($dom)));
		my $out = &call_aws_s3_cmd($akey,
		    [ @regionflag,
		      "cp", $temp, "s3://$bucket/$destfile.dom", @rrsargs ]);
		$err = $out if ($? || $out =~ /upload\s+failed/);
		}
	last if (!$err);
	}
return $err;
}

# s3_region_flag(access-key, secret-key, bucket)
# Returns the flags array needed to backup to some bucket
sub s3_region_flag
{
my ($akey, $skey, $bucket) = @_;
my @regionflag;
my $info = &s3_get_bucket($akey, $skey, $bucket);
if (ref($info) && $info->{'location'}) {
	return ("--region", $info->{'location'});
	}
return ( );
}

# s3_list_backups(access-key, secret-key, bucket, [file])
# Returns a hash reference from domain names to lists of features, or an error
# message string on failure.
sub s3_list_backups
{
my ($akey, $skey, $bucket, $path) = @_;
&require_s3();
my $files = &s3_list_files($akey, $skey, $bucket);
if (!ref($files)) {
	return &text('s3_elist2', $files);
	}
my $rv = { };
foreach my $f (@$files) {
	if ($f->{'Key'} =~ /^(\S+)\.info$/ && $path eq $1 ||
	    $f->{'Key'} =~ /^([^\/\s]+)\.info$/ && !$path ||
	    $f->{'Key'} =~ /^((\S+)\/([^\/]+))\.info$/ && $path && $path eq $2){
		# Found a valid info file .. get it
		my $bfile = $1;
		my ($bentry) = grep { $_->{'Key'} eq $bfile } @$files;
		next if (!$bentry);	# No actual backup file found!
		my $temp = &transname();
		my $err = &s3_download($akey, $skey, $bucket,
				       $f->{'Key'}, $temp);
		if (!$err) {
			my $info = &unserialise_variable(
					&read_file_contents($temp));
			foreach my $dname (keys %$info) {
				$rv->{$dname} = {
					'file' => $bfile,
					'features' => $info->{$dname},
					};
				}
			}
		else {
			return &text('s3_einfo2', $f->{'Key'}, $err);
			}
		}
	}
return $rv;
}

# s3_list_domains(access-key, secret-key, bucket, [file])
# Returns a hash reference from domain names to domain hashes, or an error
# message string on failure.
sub s3_list_domains
{
my ($akey, $skey, $bucket, $path) = @_;
&require_s3();
my $files = &s3_list_files($akey, $skey, $bucket);
if (!ref($files)) {     
	return &text('s3_elist2', $files);
	}
my $rv = { };
foreach my $f (@$files) {
	if ($f->{'Key'} =~ /^(\S+)\.dom$/ && $path eq $1 ||
	    $f->{'Key'} =~ /^([^\/\s]+)\.dom$/ && !$path ||
	    $f->{'Key'} =~ /^((\S+)\/([^\/]+))\.dom$/ && $path && $path eq $2){
		# Found a valid .dom file .. get it
		my $bfile = $1;
		my ($bentry) = grep { $_->{'Key'} eq $bfile } @$files;
		next if (!$bentry);     # No actual backup file found!
		my $temp = &transname();
		my $err = &s3_download($akey, $skey, $bucket,
				       $f->{'Key'}, $temp);
		if (!$err) {
			my $dom = &unserialise_variable(
					&read_file_contents($temp));
			foreach my $dname (keys %$dom) {
				$rv->{$dname} = $dom->{$dname};
				}
			}
		}
	}
return $rv;
}

# s3_list_buckets(access-key, secret-key)
# Returns an array ref of all buckets under some account, or an error message.
# Each is a hash ref with keys 'Name' and 'CreationDate'
sub s3_list_buckets
{
&require_s3();
my ($akey, $skey) = @_;
if (&can_use_aws_s3_cmd($akey, $skey)) {
	# Use the aws command
	my $out = &call_aws_s3_cmd($akey, [ "ls" ]);
	return $out if ($?);
	my @rv;
	foreach my $l (split(/\r?\n/, $out)) {
		my ($date, $time, $file) = split(/\s+/, $l, 3);
		push(@rv, { 'Name' => $file,
			    'CreationDate' => $date."T".$time.".000Z" });
		}
	return \@rv;
	}
else {
	# Make an HTTP API call
	my $conn = &make_s3_connection($akey, $skey);
	return $text{'s3_econn'} if (!$conn);
	my $response = $conn->list_all_my_buckets();
	if ($response->http_response->code != 200) {
		return &text('s3_elist', &extract_s3_message($response));
		}
	return $response->entries;
	}
}

# s3_get_bucket(access-key, secret-key, bucket)
# Returns a hash ref with details of a bucket. Keys are :
# location - A location like us-west-1, if any is set
# logging - XXX
# acl - An array ref of ACL objects
# lifecycle - An array ref of lifecycle rule objects
sub s3_get_bucket
{
&require_s3();
my ($akey, $skey, $bucket) = @_;
if (&can_use_aws_s3_cmd($akey, $skey)) {
	# Use the S3 API command
	my %rv;
	my $out = &call_aws_s3api_cmd($akey,
		[ "get-bucket-location", "--bucket", $bucket ], undef, 1);
	$rv->{'location'} = $out->{'LocationConstraint'} if (ref($out));
	my $out = &call_aws_s3api_cmd($akey,
		[ "get-bucket-logging", "--bucket", $bucket ], undef, 1);
	$rv->{'logging'} = $out->{'BucketLoggingStatus'} if (ref($out));
	my $out = &call_aws_s3api_cmd($akey,
		[ "get-bucket-acl", "--bucket", $bucket ], undef, 1);
	$rv->{'acl'} = $out->{'AccessControlPolicy'} if (ref($out));
	my $out = &call_aws_s3api_cmd($akey,
		[ "get-bucket-lifecycle-configuration", "--bucket", $bucket ], undef, 1);
	$rv->{'lifecycle'} = $out->{'LifecycleConfiguration'} if (ref($out));
	return \%rv;
	}
else {
	# Make an HTTP API call
	my %rv;
	my $conn = &make_s3_connection($akey, $skey);
	my $response = $conn->get_bucket_location($bucket);
	if ($response->http_response->code == 200) {
		$rv{'location'} = $response->{'LocationConstraint'};
		}
	$response = $conn->get_bucket_logging($bucket);
	if ($response->http_response->code == 200) {
		$rv{'logging'} = $response->{'BucketLoggingStatus'};
		}
	$response = $conn->get_bucket_acl($bucket);
	if ($response->http_response->code == 200) {
		$rv{'acl'} = $response->{'AccessControlPolicy'};
		}
	$response = $conn->get_bucket_lifecycle($bucket);
	if ($response->http_response->code == 200) {
		$rv{'lifecycle'} = $response->{'LifecycleConfiguration'};
		}
	return \%rv;
	}
}

# s3_put_bucket_acl(access-key, secret-key, bucket, &acl)
# Updates the ACL for a bucket, based on the structure in the format returned
# by s3_get_bucket->{'acl'}
sub s3_put_bucket_acl
{
&require_s3();
my ($akey, $skey, $bucket, $acl) = @_;
my $conn = &make_s3_connection($akey, $skey);
my $xs = XML::Simple->new(KeepRoot => 1);
my $xml = $xs->XMLout({ 'AccessControlPolicy' => [ $acl ] });
my $response = $conn->put_bucket_acl($bucket, $xml);
return $response->http_response->code == 200 ? undef : 
	&text('s3_eputacl', &extract_s3_message($response));
}

# s3_put_bucket_lifecycle(access-key, secret-key, bucket, &acl)
# Updates the lifecycle for a bucket, based on the structure in the format
# returned by s3_get_bucket->{'acl'}
sub s3_put_bucket_lifecycle
{
&require_s3();
my ($akey, $skey, $bucket, $lifecycle) = @_;
my $conn = &make_s3_connection($akey, $skey);
my $response;
if (@{$lifecycle->{'Rule'}}) {
	# Update lifecycle config
	my $xs = XML::Simple->new(KeepRoot => 1);
	my $xml = $xs->XMLout(
		{ 'LifecycleConfiguration' => [ $lifecycle ] });
	$response = $conn->put_bucket_lifecycle($bucket, $xml);
	}
else {
	# Delete lifecycle config
	$response = $conn->delete_bucket_lifecycle($bucket, $xml);
	}
return $response->http_response->code == 200 ||
       $response->http_response->code == 204 ? undef : 
	&text('s3_eputlifecycle', &extract_s3_message($response));
}

# s3_list_files(access-key, secret-key, bucket)
# Returns a list of all files in an S3 bucket as an array ref, or an error
# message string. Each is a hash ref with keys like 'Key', 'Size', 'Owner'
# and 'LastModified'
sub s3_list_files
{
my ($akey, $skey, $bucket) = @_;
if (&can_use_aws_s3_cmd($akey, $skey)) {
	# Use the aws command
	my @regionflag = &s3_region_flag($akey, $skey, $bucket);
	my $out = &call_aws_s3_cmd($akey,
		[ @regionflag,
		  "ls", "--recursive", "s3://$bucket/" ]);
	return $out if ($?);
	my @rv;
	foreach my $l (split(/\r?\n/, $out)) {
		my ($date, $time, $size, $file) = split(/\s+/, $l, 4);
		push(@rv, { 'Key' => $file,
			    'Size' => $size,
			    'LastModified' => $date."T".$time.".000Z" });
		}
	return \@rv;
	}
else {
	# Make direct API call
	&require_s3();
	my $conn = &make_s3_connection($akey, $skey);
	return $text{'s3_econn'} if (!$conn);
	my $response = $conn->list_bucket($bucket);
	if ($response->http_response->code != 200) {
		return &text('s3_elistfiles', &extract_s3_message($response));
		}
	return $response->entries;
	}
}

# s3_delete_file(access-key, secret-key, bucket, file)
# Delete one file from an S3 bucket
sub s3_delete_file
{
my ($akey, $skey, $bucket, $file) = @_;
if (&can_use_aws_s3_cmd($akey, $skey, $bucket)) {
	# Use the aws command to delete a file
	my @regionflag = &s3_region_flag($akey, $skey, $bucket);
	my $out = &call_aws_s3_cmd($akey,
		[ @regionflag,
		  "rm", "s3://$bucket/$file" ]);
	return $? ? $out : undef;
	}
else {
	# Call the HTTP API directly
	&require_s3();
	my $conn = &make_s3_connection($akey, $skey);
	return $text{'s3_econn'} if (!$conn);
	my $response = $conn->delete($bucket, $file);
	if ($response->http_response->code < 200 ||
	    $response->http_response->code >= 300) {
		return &text('s3_edeletefile', &extract_s3_message($response));
		}
	return undef;
	}
}

# s3_parse_date(string)
# Converts an S3 date string like 2007-09-30T05:58:39.000Z into a Unix time
sub s3_parse_date
{
my ($str) = @_;
if ($str =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)\.000Z/) {
	my $rv = eval { timegm($6, $5, $4, $3, $2-1, $1); };
	return $@ ? undef : $rv;
	}
elsif ($str =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)/) {
	my $rv = eval { timelocal($6, $5, $4, $3, $2-1, $1); };
	return $@ ? undef : $rv;
	}
return undef;
}

# s3_delete_bucket(access-key, secret-key, bucket, [bucket-only])
# Deletes an S3 bucket and all contents
sub s3_delete_bucket
{
my ($akey, $skey, $bucket, $norecursive) = @_;
$bucket || return "Missing bucket parameter to s3_delete_bucket";
if (&can_use_aws_s3_cmd($akey, $skey, $bucket)) {
	# Use the aws command to delete the whole bucket
	my @regionflag = &s3_region_flag($akey, $skey, $bucket);
	my $out = &call_aws_s3_cmd($akey,
		[ @regionflag,
		  "rm", "s3://$bucket", "--recursive" ]);
	return $? ? $out : undef;
	}
else {
	# Call the HTTP API directly
	&require_s3();
	my $conn = &make_s3_connection($akey, $skey);
	return $text{'s3_econn'} if (!$conn);

	if (!$norecursive) {
		# Get and delete files first
		my $files = &s3_list_files($akey, $skey, $bucket);
		return $files if (!ref($files));
		foreach my $f (@$files) {
			my $err = &s3_delete_file($akey, $skey,
						     $bucket, $f->{'Key'});
			return $err if ($err);
			}
		}

	my $response = $conn->delete_bucket($bucket);
	if ($response->http_response->code < 200 ||
	    $response->http_response->code >= 300) {
		return &text('s3_edelete', &extract_s3_message($response));
		}
	return undef;
	}
}

# s3_download(access-key, secret-key, bucket, file, destfile, tries)
# Download some file for S3 into the given destination file. Returns undef on
# success or an error message on failure.
sub s3_download
{
my ($akey, $skey, $bucket, $file, $destfile, $tries) = @_;
$tries ||= 1;
if (&can_use_aws_s3_cmd($akey, $skey)) {
	return &s3_download_aws_cmd(@_);
	}
&require_s3();

my $err;
my $endpoint = undef;
for(my $i=0; $i<$tries; $i++) {
	my $newendpoint;
	$err = undef;

	# Connect to S3
	my $conn = &make_s3_connection($akey, $skey, $endpoint);
	if (!$conn) {
		$err = $text{'s3_econn'};
		next;
		}

	# Use the S3 library to create a request object, but use Webmin's HTTP
	# function to open it.
	my $path = $endpoint ? $file : "$bucket/$file";
	my $authpath = "$bucket/$file";
	my $req = &s3_make_request($conn, $path, "GET", "dummy",
				      undef, $authpath);
	my ($host, $port, $page, $ssl) = &parse_http_url($req->uri);
	my $h = &make_http_connection(
		$host, $port, $ssl, $req->method, $page);
	my @st = stat($sourcefile);
	foreach my $hfn ($req->header_field_names) {
		&write_http_connection($h, $hfn.": ".$req->header($hfn)."\r\n");
		}
	&write_http_connection($h, "\r\n");

	# Read back response .. this needs to be our own code, as S3 does
	# some wierd redirects
	my $line = &read_http_connection($h);
	$line =~ s/\r|\n//g;

	# Read the headers
	my %rheader;
	while(1) {
		my $hline = &read_http_connection($h);
		$hline =~ s/\r\n//g;
		$hline =~ /^(\S+):\s+(.*)$/ || last;
		$rheader{lc($1)} = $2;
		}

	if ($line !~ /^HTTP\/1\..\s+(200|30[0-9])(\s+|$)/) {
		$err = "Download failed : $line";
		}
	elsif ($1 >= 300 && $1 < 400) {
		# Read the body for the redirect
		my $out;
		while(defined($buf = &read_http_connection($h, 1024))) {
			$out .= $buf;
			}
		if ($out =~ /<Endpoint>([^<]+)<\/Endpoint>/) {
			if ($endpoint ne $1) {
				$endpoint = $1;
				$err = "Redirected to $endpoint";
				$newendpoint = 1;
				$i--;	# Doesn't count as a try
				}
			else {
				$err = "Redirected to same endpoint $endpoint";
				}
			}
		else {
			$err = "Missing new endpoint in redirect : ".
				&html_escape($out);
			}
		}
	else {
		# Read the actual data to the file
		&open_tempfile(S3SAVE, ">$destfile");
		while(defined($buf = &read_http_connection($h, 1024))) {
			&print_tempfile(S3SAVE, $buf);
			}
		&close_tempfile(S3SAVE);
		}
	&close_http_connection($h);

	if ($err) {
		# Wait a little before re-trying
		sleep(10) if (!$newendpoint);
		}
	else {
		# Worked .. end of the job
		last;
		}
	}

return $err;
}

# s3_download_aws_cmd(access-key, secret-key, bucket, file, destfile, tries)
# Like s3_download, but uses the aws command
sub s3_download_aws_cmd
{
my ($akey, $skey, $bucket, $file, $destfile, $tries) = @_;
$tries ||= 1;
my $err;
my @regionflag = &s3_region_flag($akey, $skey, $bucket);
for(my $i=0; $i<$tries; $i++) {
	$err = undef;
	my $out = &call_aws_s3_cmd($akey,
		[ @regionflag,
		  "cp", "s3://$bucket/$file", $destfile ]);
	if ($?) {
		$err = $out;
		}
	last if (!$err);
	}
return $err;
}

# s3_make_request(conn, path, method, data, [&headers], [authpath])
# Create a HTTP::Request object for talking to S3, 
sub s3_make_request
{
my ($conn, $path, $method, $data, $headers, $authpath) = @_;
my $object = S3::S3Object->new($data);
$headers ||= { };
$authpath ||= $path;
my $metadata = $object->metadata;
my $merged = S3::merge_meta($headers, $metadata);
$conn->_add_auth_header($merged, $method, $authpath);
my $protocol = $conn->{IS_SECURE} ? 'https' : 'http';
my $url = "$protocol://$conn->{SERVER}:$conn->{PORT}/$path";

my @http_headers;
foreach my $h ($merged->header_field_names()) {
	push(@http_headers, lc($h), $merged->header($h));
	}
my $req = HTTP::Request->new($method, $url, \@http_headers);
$req->content($object->data);
return $req;
}

# make_s3_connection(access-key, secret-key, [endpoint])
# Returns an S3::AWSAuthConnection connection object
sub make_s3_connection
{
my ($akey, $skey, $endpoint) = @_;
my $s3 = &get_s3_account($akey);
if ($s3) {
	$endpoint ||= $s3->{'endpoint'};
	$skey ||= $s3->{'secret'};
	}
&require_s3();
my $endport;
($endpoint, $endport) = split(/:/, $endpoint);
return S3::AWSAuthConnection->new($akey, $skey, undef, $endpoint, $endport);
}

# s3_part_upload(&s3-connection, bucket, endpoint, sourcefile, destfile,
# 		 part-number, sent-offset, chunk-size, upload-id)
# Uploads a chunk of a file to S3. On success returns 1 and an etag for the
# part. On failure returns 0 and an error message.
sub s3_part_upload
{
my ($conn, $bucket, $endpoint, $sourcefile, $destfile, $part, $sent,
       $chunk, $uploadid) = @_;
my $headers = { 'Content-Length' => $chunk };
my $path = $endpoint ? $destfile : "$bucket/$destfile";
my $authpath = "$bucket/$destfile";
my $params = "?partNumber=".$part."&uploadId=".$uploadid;
$path .= $params;
$authpath .= $params;
my $req = &s3_make_request($conn, $path, "PUT", "dummy",
		$headers, $authpath);
my ($host, $port, $page, $ssl) = &parse_http_url($req->uri);

# Make the HTTP request and send headers
my $h = &make_http_connection($host, $port, $ssl, $req->method, $page);
if (!ref($h)) {
	return (0, "HTTP connection to ${host}:${port} for $page failed : $h");
	}
foreach my $hfn ($req->header_field_names) {
	&write_http_connection($h, $hfn.": ".$req->header($hfn)."\r\n");
	}
&write_http_connection($h, "\r\n");

# Send the chunk
local $SIG{'PIPE'} = 'IGNORE';
my $buf;
open(BACKUP, "<".$sourcefile);
seek(BACKUP, $sent, 0);
my $got = 0;
while(1) {
	my $want = $chunk - $got;
	last if (!$want);
	my $read = read(BACKUP, $buf, $want);
	if ($read <= 0) {
		close(BACKUP);
		return (0, "Read failed for $want : $!");
		}
	$got += $read;
	&write_http_connection($h, $buf);
	}
close(BACKUP);

# Start reading back the response
my $line = &read_http_connection($h);
$line =~ s/\r|\n//g;

# Read the headers
my %rheader;
while(1) {
	my $hline = &read_http_connection($h);
	$hline =~ s/\r\n//g;
	$hline =~ /^(\S+):\s+(.*)$/ || last;
	$rheader{lc($1)} = $2;
	}

# Read the body
my $out;
while(defined($buf = &read_http_connection($h, 1024))) {
	$out .= $buf;
	}
&close_http_connection($h);

if ($line !~ /^HTTP\/1\..\s+(200|30[0-9])(\s+|$)/) {
	return (0, "Upload failed : $line \n\nTry installing `awscli` package using package manager");
	}
elsif (!$rheader{'etag'}) {
	return (0, "Response missing etag header : $out \n\nTry installing `awscli` package using package manager");
	}

$rheader{'etag'} =~ s/^"(.*)"$/$1/;
return (1, $rheader{'etag'});
}

# s3_list_locations(access-key, secret-key)
# Returns a list of all possible S3 locations for buckets. Currently this is
# only supported for AWS.
sub s3_list_locations
{
my ($akey, $skey) = @_;
my $s3 = &get_s3_account($akey) || &get_default_s3_account();
return () if (!$s3);
if ($s3->{'endpoint'}) {
	return ( "us-east-1", "us-west-1", "us-west-2", "af-south-1", "ap-east-1", "ap-south-2", "ap-southeast-3", "ap-southeast-4", "ap-south-1", "ap-northeast-3", "ap-northeast-2", "ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "ca-central-1", "ca-west-1", "eu-central-1", "eu-west-1", "eu-west-2", "eu-south-1", "eu-west-3", "eu-south-2", "eu-north-1", "eu-central-2", "il-central-1", "me-south-1", "me-central-1", "sa-east-1", "us-gov-east-1", "us-gov-west-1");
	}
else {
	return ();
	}
}

# can_use_aws_s3_creds()
# Returns 1 if the AWS command can be used with local credentials, such as on
# an EC2 instance with IAM
sub can_use_aws_s3_creds
{
return 0 if (!&has_aws_cmd());
my $ok = &can_use_aws_cmd(undef, undef, undef, \&call_aws_s3_cmd, "ls");
return 0 if (!$ok);
return &has_aws_ec2_creds() ? 1 : 0;
}

# can_use_aws_s3_cmd(access-key, secret-key, [default-zone])
# Returns 1 if the aws command can be used to access S3
sub can_use_aws_s3_cmd
{
my ($akey, $skey, $zone) = @_;
return &can_use_aws_cmd($akey, $skey, $zone, \&call_aws_s3_cmd, "ls");
}

# can_use_aws_cmd(access-key, secret-key, [default-zone], &testfunc, cmd, ...)
# Returns 1 if the aws command is installed and can be used for uploads and
# downloads
sub can_use_aws_cmd
{
my ($akey, $skey, $zone, $func, @cmd) = @_;
my $s3 = &get_s3_account($akey);
$skey ||= $s3->{'secret'} if ($s3);
my $acachekey = $akey || "none";
if (!&has_aws_cmd()) {
	return wantarray ? (0, "The <tt>aws</tt> command is not installed") : 0;
	}
if (defined($can_use_aws_cmd_cache{$acachekey})) {
	return wantarray ? @{$can_use_aws_cmd_cache{$acachekey}}
			 : $can_use_aws_cmd_cache{$acachekey}->[0];
	}
my $out = &$func($akey, @cmd);
if ($? || $out =~ /Unable to locate credentials/i ||
	  $out =~ /could not be found/) {
	# Credentials profile hasn't been setup yet
	if (!$akey) {
		# No access key was given, and default credentials don't work
		my $err = "No default AWS credentials have been configured";
		$can_use_aws_cmd_cache{$acachekey} = [0, $err];
		return wantarray ? (0, $out) : 0;
		}
	else {
		# Try to create a profile with the given credentials
		my $temp = &transname();
		&open_tempfile(TEMP, ">$temp");
		&print_tempfile(TEMP, $akey,"\n");
		&print_tempfile(TEMP, $skey,"\n");
		&print_tempfile(TEMP, $zone,"\n");
		&print_tempfile(TEMP, "\n");
		&close_tempfile(TEMP);
		my $aws = $config{'aws_cmd'} || "aws";
		$out = &backquote_command(
			"$aws configure --profile=".quotemeta($akey).
			" <$temp 2>&1");
		my $ex = $?;
		if (!$ex) {
			# Test again to make sure it worked
			$out = &$func($akey, @cmd);
			$ex = $?;
			}
		if ($ex) {
			# Profile setup failed!
			$can_use_aws_cmd_cache{$acachekey} = [0, $out];
			return wantarray ? (0, $out) : 0;
			}
		}
	}
$can_use_aws_cmd_cache{$acachekey} = [1, undef];
return wantarray ? (1, undef) : 1;
}

# call_aws_s3_cmd(akey, params, [endpoint])
# Run the aws command for s3 with some params, and return output
sub call_aws_s3_cmd
{
my ($akey, $params, $endpoint) = @_;
my $s3 = &get_s3_account($akey);
$endpoint ||= $s3->{'endpoint'} if ($s3);
return &call_aws_cmd($akey, "s3", $params, $endpoint);
}

# call_aws_s3api_cmd(akey, params, [endpoint], [parse-json])
# Run the aws command for s3api with some params, and return output
sub call_aws_s3api_cmd
{
my ($akey, $params, $endpoint, $json) = @_;
$endpoint ||= $config{'s3_endpoint'};
my $out = &call_aws_cmd($akey, "s3api", $params, $endpoint);
if (!$? && $json) {
	eval "use JSON::PP";
	my $coder = JSON::PP->new->pretty;
	eval {
		$out = $coder->decode($out);
		};
	}
return $out;
}

# call_aws_cmd(akey, command, params, endpoint)
# Run the aws command for s3 with some params, and return output
sub call_aws_cmd
{
my ($akey, $cmd, $params, $endpoint) = @_;
my $endpoint_param;
if ($endpoint) {
	$endpoint_param = "--endpoint-url=".quotemeta("https://$endpoint");
	}
if (ref($params)) {
	$params = join(" ", map { quotemeta($_) } @$params);
	}
my $aws = $config{'aws_cmd'} || "aws";
my ($out, $err);
&execute_command(
	"TZ=GMT $aws $cmd ".
	($akey ? "--profile=".quotemeta($akey)." " : "").
	$endpoint_param." ".$params, undef, \$out, \$err);
return $out if (!$?);
return $err || $out;
}

# has_aws_cmd()
# Returns 1 if the configured "aws" command is installed, minus flags
sub has_aws_cmd
{
my ($cmd) = &split_quoted_string($config{'aws_cmd'} || "aws");
return &has_command($cmd);
}

# has_aws_ec2_creds()
# Check if the config file says to get credentials from EC2 metadata
sub has_aws_ec2_creds
{
my $cfile = "/root/.aws/credentials";
return 2 if (!-r $cfile);	# Credentials magically work with no config,
				# which means they are provided by EC2
my $lref = &read_file_lines($cfile, 1);
my %defv;
foreach my $l (@$lref) {
	if ($l =~ /^\s*\[(\S+)\]/) {
		$indef = $1 eq "default" ? 1 : 0;
		}
	elsif ($l =~ /^\s*(\S+)\s*=\s*(\S+)/ && $indef) {
		$defv{$1} = $2;
		}
	}
if ($defv{'credential_source'} eq 'Ec2InstanceMetadata') {
	return 1;
	}
return 0;
}

# get_ec2_aws_region()
# If we're hosted on EC2, return the region name
sub get_ec2_aws_region
{
my ($out, $err);
&http_download("169.254.169.254", 80,
	       "/latest/dynamic/instance-identity/document", \$out, \$err,
	       undef, 0, undef, undef, 1);
return undef if ($err);
return $out =~ /"region"\s*:\s*"(\S+)"/ ? $1 : undef;
}

# list_s3_accounts()
# Returns a list of hash refs each containing the details of one S3 account
# registered with Virtualmin
sub list_s3_accounts
{
my @rv;
if ($config{'s3_akey'}) {
	push(@rv, { 'access' => $config{'s3_akey'},
		    'secret' => $config{'s3_skey'},
		    'endpoint' => $config{'s3_endpoint'},
		    'location' => $config{'s3_location'},
		    'desc' => $config{'s3_desc'},
		    'id' => 1,
		    'default' => 1, });
	}
if (opendir(DIR, $s3_accounts_dir)) {
	foreach my $f (sort { $a cmp $b } readdir(DIR)) {
		next if ($f eq "." || $f eq "..");
		my %account;
		&read_file("$s3_accounts_dir/$f", \%account);
		push(@rv, \%account);
		}
	closedir(DIR);
	}
return @rv;
}

# get_s3_account(access-key)
# Returns an account looked up by key, or undef
sub get_s3_account
{
my ($akey) = @_;
my $rv = $get_s3_account_cache{$akey};
if (!$rv) {
	($rv) = grep { $_->{'access'} eq $akey } &list_s3_accounts();
	$get_s3_account_cache{$akey} = $rv if ($rv);
	}
return $rv;
}

# get_default_s3_account()
# Returns the first or default S3 account
sub get_default_s3_account
{
my @s3s = &list_s3_accounts();
return undef if (!@s3s);
my ($s3) = grep { $_->{'default'} } @s3s;
$s3 ||= $s3s[0];
return $s3;
}

# lookup_s3_credentials([access-key], [secret-key])
# Returns either the default access and secret key, or the secret key from
# the account matching the access key
sub lookup_s3_credentials
{
my ($akey, $skey) = @_;
if ($akey && $skey) {
	return ($akey, $skey);
	}
my $s3 = $akey ? &get_s3_account($akey) : &get_default_s3_account();
return $s3 ? ( $s3->{'access'}, $s3->{'secret'} ) : ( );
}

# save_s3_account(&account)
# Create or update an S3 account
sub save_s3_account
{
my ($account) = @_;
if ($account->{'default'}) {
	&lock_file($module_config_file);
	$config{'s3_akey'} = $account->{'access'};
	$config{'s3_skey'} = $account->{'secret'};
	$config{'s3_endpoint'} = $account->{'endpoint'};
	$config{'s3_location'} = $account->{'location'};
	$config{'s3_desc'} = $account->{'desc'};
	&unlock_file($module_config_file);
	&save_module_config();
	}
else {
	$account->{'id'} ||= &domain_id();
	&make_dir($s3_accounts_dir, 0700) if (!-d $s3_accounts_dir);
	my $file = "$s3_accounts_dir/$account->{'id'}";
	&lock_file($file);
	&write_file($file, $account);
	&unlock_file($file);
	}
}

# delete_s3_account(&account)
# Remove one S3 account from Virtualmin
sub delete_s3_account
{
my ($account) = @_;
my $akey = $account->{'access'};
if ($account->{'default'}) {
	&lock_file($module_config_file);
	delete($config{'s3_akey'});
	delete($config{'s3_skey'});
	delete($config{'s3_endpoint'});
	delete($config{'s3_location'});
	&unlock_file($module_config_file);
	&save_module_config();
	}
else {
	$account->{'id'} || &error("Missing account ID!");
	my $file = "$s3_accounts_dir/$account->{'id'}";
	&unlink_logged($file);
	}

# Also clear the AWS creds
my @uinfo = getpwnam("root");
foreach my $f ("$uinfo[7]/.aws/config", "$uinfo[7]/.aws/credentials") {
	&lock_file($f);
	my $lref = &read_file_lines($f);
	my ($start, $end, $inside) = (-1, -1, 0);
	for(my $i=0; $i<@$lref; $i++) {
		if ($lref->[$i] =~ /^\[(profile\s+)?\Q$akey\E\]$/) {
			$start = $end = $i;
			$inside = 1;
			}
		elsif ($lref->[$i] =~ /^\S+\s*=\s*\S+/ && $inside) {
			$end = $i;
			}
		else {
			$inside = 0;
			}
		}
	if ($start >= 0) {
		splice(@$lref, $start, $end-$start+1);
		}
	&flush_file_lines($f);
	&unlock_file($f);
	}
}

# backup_uses_s3_account(&sched, &account)
# Returns 1 if a scheduled backup uses an S3 account
sub backup_uses_s3_account
{
my ($sched, $account) = @_;
foreach my $dest (&get_scheduled_backup_dests($sched)) {
	my ($mode, $akey) = &parse_backup_url($dest);
	if ($mode == 3 &&
	    ($akey eq $account->{'access'} ||
	     !$akey && $account->{'default'})) {
		return 1;
		}
	}
return 0;
}

# create_s3_accounts_from_backups()
# If any scheduled backups use S3, create S3 accounts from their creds
sub create_s3_accounts_from_backups
{
my @s3s = &list_s3_accounts();
foreach my $sched (&list_scheduled_backups()) {
	foreach my $dest (&get_scheduled_backup_dests($sched)) {
		my ($mode, $akey, $skey) = &parse_backup_url($dest);
		if ($mode == 3) {
			my ($s3) = grep { $_->{'access'} eq $akey &&
					  $_->{'secret'} eq $skey } @s3s;
			if (!$s3) {
				$s3 = { 'access' => $akey,
					'secret' => $skey,
					'desc' => "S3 account from backup ".
						  $sched->{'desc'},
				        'endpoint' => $config{'s3_endpoint'},
				      };
				&save_s3_account($s3);
				push(@s3s, $s3);
				}
			}
		}
	}
}

1;

