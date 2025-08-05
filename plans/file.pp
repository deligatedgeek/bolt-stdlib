plan stdlib::file(
  TargetSpec $targets,
  Array[Hash] $files = [],
  Boolean $check_only = false,
  Boolean $fail_on_non_compliance = true
) {
  # Install jq package
  $install_task_result = run_task(
    'package', $targets,
    'name' => 'jq',
    'action' => 'install',
    'manager_options' => '--enablerepo=epel',
  )
  unless $install_task_result.ok {
    fail_plan("Install of jq failed with status: ${status}  version: ${version}")
  }
  # Run the compliance check/fix task
  $results = run_task('stdlib::check_fix_files', $targets, {
      'files' => $files,
      'check_only' => $check_only
  })

  # Process results
  $results.each |$result| {
    $target = $result.target.name
    $output = $result.value

    out::message("=== File Compliance Results for ${target} ===")
    out::message("Status: ${output['status']}")
    out::message("Files checked: ${output['files_checked']}")
    out::message("Files fixed: ${output['files_fixed']}")

    if $output['compliance_issues'].length > 0 {
      out::message("Compliance issues found:")
      $output['compliance_issues'].each |$issue_set| {
        $issue_set.each |$issue| {
          out::message("  - ${issue}")
        }
      }
    }

    out::message("Detailed results:")
    $output['details'].each |$detail| {
      out::message("  ${detail['file']}: ${detail['status']} - ${detail['message']}")
      if $detail['issues_fixed'] {
        out::message("    Fixes applied: ${detail['issues_fixed'].join(', ')}")
      }
    }

    # Fail the plan if there are compliance issues and fail_on_non_compliance is true
    if $fail_on_non_compliance and ($output['status'] == 'non_compliant' or $output['status'] == 'partial_failure') {
      fail("File compliance issues found on ${target}")
    }
  }

  return $results
}
