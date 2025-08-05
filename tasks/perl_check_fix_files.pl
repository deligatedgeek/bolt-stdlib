#!/usr/bin/perl

use strict;
use warnings;
#use JSON;
#use Digest::SHA qw(sha256_hex);
use File::stat;
use File::Copy;
use Data::Dumper;

# Only execute main logic if script is run directly (not required)
if (!caller) {
    # Read JSON input from STDIN
    my $input_json = do { local $/; <STDIN> };
    my $input = parse_json($input_json);
    # print Dumper($input); # Debug output removed for integration tests

    my $check_only = $input->{check_only} // 0;
    my $files_config = $input->{files} // {};

    # Initialize counters and result structures
    my $files_checked = 0;
    my $files_fixed = 0;
    my @compliance_issues = ();
    my @details = ();
    my $overall_status = "success";

    # Handle both array and object formats for files configuration
    my @file_configs_to_process;
    if (ref($files_config) eq 'ARRAY') {
        # Array format: [{"path": "...", "content": "..."}, ...]
        @file_configs_to_process = @$files_config;
    } elsif (ref($files_config) eq 'HASH') {
        # Object format: {"key1": {"path": "...", "content": "..."}, "key2": {...}}
        @file_configs_to_process = values %$files_config;
    }

    # Process each file configuration
    for my $file_config (@file_configs_to_process) {
        my $file_path = $file_config->{path} // '';
        next if $file_path eq '';
        
        my $required_mode = $file_config->{mode} // '';
        my $required_owner = $file_config->{owner} // '';
        my $required_group = $file_config->{group} // '';
        my $required_content = $file_config->{content} // '';
        my $content_source = $file_config->{content_source} // '';
        
        $files_checked++;

        # Check file compliance
        my ($compliant, $issues) = check_file_compliance(
            $file_path, $required_mode, $required_owner, $required_group, 
            $required_content, $content_source
        );
        
        # Store compliance results
        my $file_detail = {
            path => $file_path,
            compliant => $compliant ? 1 : 0,
            issues => $issues // []
        };
        
        if (!$compliant) {
            push @compliance_issues, @{$issues // []};
            
            if (!$check_only) {
                # Attempt to fix the issues
                my ($success, $fixes) = fix_file_compliance(
                    $file_path, $required_mode, $required_owner, $required_group,
                    $required_content, $content_source, $issues
                );
                
                if ($success) {
                    $files_fixed++;
                    $file_detail->{fixes_applied} = $fixes // [];
                } else {
                    $file_detail->{error} = {
                        type => "fix_failed",
                        message => "Failed to fix compliance issues"
                    };
                    $overall_status = "partial_failure";
                }
            }
        }
        
        push @details, $file_detail;
    }

    # Build and output JSON result
    my $result = {
        status => $overall_status,
        files_checked => $files_checked,
        files_fixed => $files_fixed,
        compliance_issues => \@compliance_issues,
        details => \@details
    };

    print encode_json($result);
    exit 0;
}

sub parse_json {
    my ($json_str) = @_;
    
    # Basic JSON validation - must start with { and end with }
    $json_str =~ s/^\s+|\s+$//g; # trim whitespace
    
    if (!$json_str || $json_str !~ /^\{.*\}$/) {
        print STDERR '{"status": "error", "message": "Invalid JSON format - must be a JSON object"}' . "\n";
        exit 1;
    }
    
    # Check for basic JSON syntax errors
    if ($json_str =~ /"[^"]*":\s*[^",}\s]+[^",}\s\d]/ && $json_str !~ /"[^"]*":\s*(true|false|null|\d+)/) {
        # This catches cases like "key": json (unquoted non-boolean/non-numeric values)
        print STDERR '{"status": "error", "message": "Invalid JSON syntax - unquoted string values"}' . "\n";
        exit 1;
    }
    
    my %params;
    
    # Remove outer braces
    $json_str =~ s/^\s*\{//;
    $json_str =~ s/\}\s*$//;
    
    # Return empty hash if no content
    return \%params if !$json_str || $json_str =~ /^\s*$/;
    
    # Parse key-value pairs with improved nested object handling
    my $pos = 0;
    while ($pos < length($json_str)) {
        # Find next key
        if ($json_str =~ /"([^"]+)"\s*:\s*/g) {
            my $key = $1;
            $pos = pos($json_str);
            
            # Parse the value
            my $value;
            my $char = substr($json_str, $pos, 1);
            
            if ($char eq '"') {
                # String value
                if ($json_str =~ /\G"([^"]*)"/g) {
                    $value = $1;
                    $params{$key} = $value;
                    $pos = pos($json_str);
                }
            } elsif ($char eq '{') {
                # Nested object - find matching closing brace
                my $brace_count = 1;
                my $start_pos = $pos + 1;
                $pos++;
                
                while ($pos < length($json_str) && $brace_count > 0) {
                    my $c = substr($json_str, $pos, 1);
                    if ($c eq '{') {
                        $brace_count++;
                    } elsif ($c eq '}') {
                        $brace_count--;
                    }
                    $pos++;
                }
                
                my $nested_content = substr($json_str, $start_pos, $pos - $start_pos - 1);
                
                if ($key eq 'files') {
                    # Parse files object structure
                    my %files_hash;
                    
                    # Parse nested file objects: "key": {"path": "...", "content": "..."}
                    while ($nested_content =~ /"([^"]+)"\s*:\s*\{([^}]+)\}/g) {
                        my ($file_key, $file_props) = ($1, $2);
                        my %file_config;
                        
                        # Parse file properties
                        while ($file_props =~ /"([^"]+)"\s*:\s*"([^"]*)"/g) {
                            $file_config{$1} = $2;
                        }
                        
                        $files_hash{$file_key} = \%file_config;
                    }
                    
                    $params{$key} = \%files_hash;
                }
            } elsif ($json_str =~ /\G(true|false|null|\d+)/g) {
                # Boolean, null, or number
                $value = $1;
                if ($value eq 'true') {
                    $params{$key} = 1;
                } elsif ($value eq 'false') {
                    $params{$key} = 0;
                } elsif ($value eq 'null') {
                    $params{$key} = undef;
                } else {
                    $params{$key} = $value;
                }
                $pos = pos($json_str);
            }
            
            # Skip to next key-value pair
            while ($pos < length($json_str) && substr($json_str, $pos, 1) =~ /[\s,]/) {
                $pos++;
            }
            pos($json_str) = $pos;
        } else {
            last;
        }
    }
    
    return \%params;
}

# Simple JSON encoder for basic structures
sub encode_json {
    my ($data) = @_;
    
    if (ref($data) eq 'HASH') {
        my @pairs;
        for my $key (sort keys %$data) {
            my $json_key = qq{"$key"};
            my $json_value = encode_json_value($data->{$key});
            push @pairs, "$json_key: $json_value";
        }
        return "{" . join(", ", @pairs) . "}";
    } elsif (ref($data) eq 'ARRAY') {
        my @values = map { encode_json_value($_) } @$data;
        return "[" . join(", ", @values) . "]";
    } else {
        return encode_json_value($data);
    }
}

sub encode_json_value {
    my ($value) = @_;
    
    return "null" unless defined $value;
    
    if (ref($value) eq 'HASH') {
        return encode_json($value);
    } elsif (ref($value) eq 'ARRAY') {
        return encode_json($value);
    } elsif ($value =~ /^[01]$/ && length($value) == 1) {
        # Boolean (1 or 0) - check this before general integer pattern
        return $value ? "true" : "false";
    } elsif ($value =~ /^\d+$/) {
        # Integer
        return $value;
    } else {
        # String - escape quotes and backslashes
        $value =~ s/\\/\\\\/g;
        $value =~ s/"/\\"/g;
        $value =~ s/\n/\\n/g;
        $value =~ s/\r/\\r/g;
        $value =~ s/\t/\\t/g;
        return qq{"$value"};
    }
}

# Function to get file owner name from UID
sub get_owner_name {
    my $uid = shift;
    my $name = getpwuid($uid);
    return $name || $uid;
}

# Function to get file group name from GID
sub get_group_name {
    my $gid = shift;
    my $name = getgrgid($gid);
    return $name || $gid;
}

# Function to get UID from username
sub get_uid {
    my $username = shift;
    my $uid = getpwnam($username);
    return defined $uid ? $uid : -1;
}

# Function to get GID from group name
sub get_gid {
    my $groupname = shift;
    my $gid = getgrnam($groupname);
    return defined $gid ? $gid : -1;
}

# Function to check file compliance
sub check_file_compliance {
    my ($file_path, $required_mode, $required_owner, $required_group, $required_content, $content_source) = @_;
    my @issues = ();
    my $compliant = 1;
    
    # Check if file exists
    unless (-f $file_path) {
        push @issues, "file_missing";
        return (0, \@issues);
    }
    
    my $stat = stat($file_path);
    return (0, ["stat_failed: Cannot stat file $file_path"]) unless $stat;
    
    # Check permissions
    if (defined $required_mode && $required_mode ne '') {
        my $current_mode = sprintf("%o", $stat->mode & 07777);
        if ($current_mode ne $required_mode) {
            push @issues, "mode_mismatch: current=$current_mode, required=$required_mode";
            $compliant = 0;
        }
    }
    
    # Check owner
    if (defined $required_owner && $required_owner ne '') {
        my $current_owner = get_owner_name($stat->uid);
        if ($current_owner ne $required_owner) {
            push @issues, "owner_mismatch: current=$current_owner, required=$required_owner";
            $compliant = 0;
        }
    }
    
    # Check group
    if (defined $required_group && $required_group ne '') {
        my $current_group = get_group_name($stat->gid);
        if ($current_group ne $required_group) {
            push @issues, "group_mismatch: current=$current_group, required=$required_group";
            $compliant = 0;
        }
    }
    
    # Check content
    my $target_content = $required_content;
    
    if (defined $content_source && $content_source ne '' && -f $content_source) {
        open my $fh, '<', $content_source or do {
            push @issues, "content_source_read_error: Cannot read $content_source";
            $compliant = 0;
            return ($compliant, \@issues);
        };
        $target_content = do { local $/; <$fh> };
        close $fh;
    }
    
    if (defined $target_content && $target_content ne '') {
        open my $fh, '<', $file_path or do {
            push @issues, "content_read_error: Cannot read $file_path";
            $compliant = 0;
            return ($compliant, \@issues);
        };
        my $current_content = do { local $/; <$fh> };
        close $fh;
        
        # my $current_hash = sha256_hex($current_content);
        my $current_hash = open( my $fh1, '-|', 'echo $current_content|sha256sum');
        print Dumper($current_hash);
        # my $target_hash = sha256_hex($target_content);
        my $target_hash = open( my $fh2, '-|', 'echo $target_content|sha256sum');
        print "$target_hash\n";

        if ($current_hash ne $target_hash) {
            push @issues, "content_mismatch: content differs from requirement";
            $compliant = 0;
        }
    }
    
    return ($compliant, \@issues);
}

# Function to fix file compliance
sub fix_file_compliance {
    my ($file_path, $required_mode, $required_owner, $required_group, $required_content, $content_source, $issues_ref) = @_;
    my @issues = @$issues_ref;
    my @fixes_applied = ();
    my $success = 1;
    my $error_msg = "";
    
    # Create file if missing
    if (grep /^file_missing$/, @issues) {
        open my $fh, '>', $file_path or do {
            return (0, "Failed to create file: $file_path - $!");
        };
        close $fh;
        push @fixes_applied, "created_file";
    }
    
    # Fix content first (if needed and file creation succeeded)
    if ($success && (grep(/^content_mismatch/, @issues) || grep(/^file_missing/, @issues))) {
        my $target_content = $required_content;
        
        if (defined $content_source && $content_source ne '' && -f $content_source) {
            open my $source_fh, '<', $content_source or do {
                return (0, "Failed to read content source: $content_source - $!");
            };
            $target_content = do { local $/; <$source_fh> };
            close $source_fh;
        }
        
        if (defined $target_content && $target_content ne '') {
            open my $fh, '>', $file_path or do {
                return (0, "Failed to write content to file: $file_path - $!");
            };
            print $fh $target_content;
            close $fh;
            if (grep /^content_mismatch/, @issues) {
                push @fixes_applied, "fixed_content";
            } else {
                push @fixes_applied, "wrote_content";
            }
        }
    }
    
    # Fix permissions
    if ($success && grep /^mode_mismatch/, @issues && defined $required_mode && $required_mode ne '') {
        my $mode = oct($required_mode);
        if (chmod $mode, $file_path) {
            push @fixes_applied, "fixed_permissions";
        } else {
            return (0, "Failed to set permissions on file: $file_path - $!");
        }
    }
    
    # Fix owner and group
    if ($success && (defined $required_owner || defined $required_group)) {
        my $uid = -1;
        my $gid = -1;
        
        if (defined $required_owner && $required_owner ne '') {
            $uid = get_uid($required_owner);
            if ($uid == -1) {
                return (0, "Unknown user: $required_owner");
            }
        }
        
        if (defined $required_group && $required_group ne '') {
            $gid = get_gid($required_group);
            if ($gid == -1) {
                return (0, "Unknown group: $required_group");
            }
        }
        
        if (chown $uid, $gid, $file_path) {
            push @fixes_applied, "fixed_owner" if defined $required_owner && $required_owner ne '';
            push @fixes_applied, "fixed_group" if defined $required_group && $required_group ne '';
        } else {
            return (0, "Failed to change ownership of file: $file_path - $!");
        }
    }
    
    return (1, \@fixes_applied);
}

1; # Return true value for module loading
