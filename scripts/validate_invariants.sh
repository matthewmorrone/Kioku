#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

RG_BIN=""
if command -v rg >/dev/null 2>&1; then
  RG_BIN="$(command -v rg)"
elif [[ -x "/opt/homebrew/bin/rg" ]]; then
  RG_BIN="/opt/homebrew/bin/rg"
elif [[ -x "/usr/local/bin/rg" ]]; then
  RG_BIN="/usr/local/bin/rg"
fi

EXIT_CODE=0

list_swift_files() {
  if [[ -n "$RG_BIN" ]]; then
    "$RG_BIN" --files Kioku --glob '*.swift' | sort
    return
  fi

  find Kioku -type f -name '*.swift' | sort
}

search_swift_files() {
  local perl_pattern="$1"
  local is_multiline="${2:-false}"

  if [[ -n "$RG_BIN" ]]; then
    if [[ "$is_multiline" == "true" ]]; then
      "$RG_BIN" -nU --glob '*.swift' "$perl_pattern" Kioku || true
    else
      "$RG_BIN" -n --glob '*.swift' "$perl_pattern" Kioku || true
    fi
    return
  fi

  local find_args=(-type f -name '*.swift')
  if [[ "$is_multiline" == "true" ]]; then
    find Kioku "${find_args[@]}" -print0 | xargs -0 perl -0ne '
      while (/'"$perl_pattern"'/gms) {
        $line = substr($_, 0, pos($_));
        $line_number = ($line =~ tr/\n//) + 1;
        print "$ARGV:$line_number:$&\n";
      }
    ' 2>/dev/null || true
    return
  fi

  find Kioku "${find_args[@]}" -print0 | xargs -0 perl -ne '
    if (/'"$perl_pattern"'/) {
      print "$ARGV:$.:$_";
    }
  ' 2>/dev/null || true
}

report_failure() {
  echo "FAIL: $1"
  EXIT_CODE=1
}

report_group_matches() {
  local title="$1"
  local matches="$2"

  if [[ -n "$matches" ]]; then
    report_failure "$title"
    printf '%s\n' "$matches"
  fi
}

# Invariant 4: Swift files should never exceed 1,000 lines.
while IFS= read -r file_path; do
  line_count=$(wc -l < "$file_path")
  if (( line_count > 1000 )); then
    report_failure "Swift file exceeds 1000 lines: ${file_path} (${line_count} lines)"
  fi
done < <(list_swift_files)

# Invariant 1: Avoid while true loops.
while_true_matches=$(search_swift_files 'while[[:space:]]+true\b')
report_group_matches "Found forbidden while true loop(s)." "$while_true_matches"

# Invariant 2: Avoid empty catch blocks (single-line and simple multiline forms).
empty_catch_single=$(search_swift_files 'catch[[:space:]]*\{[[:space:]]*\}')
report_group_matches "Found empty catch block(s) on a single line." "$empty_catch_single"

empty_catch_multiline=$(search_swift_files 'catch[[:space:]]*\{[[:space:]\n]*\}' true)
report_group_matches "Found empty catch block(s) in multiline form." "$empty_catch_multiline"

# Invariant 6: Every function needs an intent comment immediately above it (ignoring blank/attribute lines).
while IFS= read -r file_path; do
  awk -v file_path="$file_path" '
  function is_blank(line) {
    return line ~ /^[[:space:]]*$/
  }
  function is_attribute(line) {
    return line ~ /^[[:space:]]*@/
  }
  function is_line_comment(line) {
    return line ~ /^[[:space:]]*\/\//
  }
  {
    lines[NR] = $0
  }
  END {
    for (i = 1; i <= NR; i++) {
      if (lines[i] ~ /\<func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/) {
        j = i - 1
        while (j >= 1 && (is_blank(lines[j]) || is_attribute(lines[j]))) {
          j--
        }
        if (j < 1 || !is_line_comment(lines[j])) {
          printf("%s:%d: function is missing intent comment immediately above declaration\n", file_path, i)
          missing = 1
        }
      }
    }
    if (missing == 1) {
      exit 1
    }
  }
  ' "$file_path" || EXIT_CODE=1
done < <(list_swift_files)

# Invariant 7: Every View/UIViewRepresentable needs an ownership comment immediately above type declaration.
while IFS= read -r file_path; do
  awk -v file_path="$file_path" '
  function is_blank(line) {
    return line ~ /^[[:space:]]*$/
  }
  function is_line_comment(line) {
    return line ~ /^[[:space:]]*\/\//
  }
  {
    lines[NR] = $0
  }
  END {
    for (i = 1; i <= NR; i++) {
      if (lines[i] ~ /^[[:space:]]*(struct|class|actor)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*.*\<(View|UIViewRepresentable)\>/) {
        j = i - 1
        while (j >= 1 && is_blank(lines[j])) {
          j--
        }
        if (j < 1 || !is_line_comment(lines[j])) {
          printf("%s:%d: View/UIViewRepresentable is missing ownership comment immediately above declaration\n", file_path, i)
          missing = 1
        }
      }
    }
    if (missing == 1) {
      exit 1
    }
  }
  ' "$file_path" || EXIT_CODE=1
done < <(list_swift_files)

if (( EXIT_CODE == 0 )); then
  echo "Invariant checks passed."
else
  echo "Invariant checks failed."
fi

exit "$EXIT_CODE"
