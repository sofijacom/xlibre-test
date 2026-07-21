#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# === НАСТРОЙКИ ===
MAINTAINER_LINE='maintainer="Rich <rich@bandaholics.cash>"'
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
PKG_DIR="${PKG_DIR:-srcpkgs}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# === ПОМОЩЬ ПО API ===
github_api() {
	local url="$1"
	if [[ -n "$TOKEN" ]]; then
		curl -fsSL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $TOKEN" "$url"
	else
		curl -fsSL -H "Accept: application/vnd.github+json" "$url"
	fi
}

gitlab_api() {
	local url="$1"
	curl -fsSL "$url"
}

# === БЕЗОПАСНЫЙ source ШАБЛОНА ===
template_var() {
	local template="$1"
	local var_name="$2"
	local arch="${3:-}"

	bash -c '
set -eo pipefail
template="$1"
var_name="$2"
arch="${3:-}"

# Эмуляция xbps-src функций
vopt_if() { :; }
vbin() { printf "%s" "$1"; }
vlicense() { printf "%s" "$1"; }
XBPS_SET_LIBDIR=1
XBPS_TARGET_MACHINE="${arch:-x86_64}"

# Подавляем ошибки вроде "command not found"
source "$template" 2>/dev/null || true

printf "%s" "${var_name:-}"
' _ "$template" "$var_name" "$arch"
}

# === ОПРЕДЕЛЕНИЕ РЕПО ===
repo_from_distfiles() {
	local distfiles="$1"
	local first_url="${distfiles%% *}"

	# x11libre.org/archive/pkg-ver.tar.xz
	if [[ "$first_url" =~ x11libre\.org/archive/([^/-]+)-([0-9.]+)\.tar\. ]]; then
		printf 'X11Libre/%s' "${BASH_REMATCH[1]}"
		return 0
	fi

	# gitlab.com/x11libre/pkg
	if [[ "$first_url" =~ gitlab\.com/x11libre/([^/]+)/ ]]; then
		printf 'X11Libre/%s' "${BASH_REMATCH[1]}"
		return 0
	fi

	# github.com/user/repo
	if [[ "$first_url" =~ github\.com/([^/]+/[^/]+)/ ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi

	# gitlab.com/user/repo
	if [[ "$first_url" =~ gitlab\.com/([^/]+/[^/]+)/ ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi

	return 1
}

# === ПОИСК ПОСЛЕДНЕГО ТЕГА ===
latest_tag_for_repo() {
	local repo="$1"
	local provider="${repo_provider:-github}"
	local releases_json tags_json candidates=""

	# GitHub
	if [[ "$provider" == "github" ]]; then
		if releases_json="$(github_api "https://api.github.com/repos/${repo}/releases?per_page=100")"; then
			candidates+="$(jq -r '.[] | select((.prerelease | not) and (.draft | not)) | .tag_name' <<<"$releases_json")"$'\n'
		fi
		if tags_json="$(github_api "https://api.github.com/repos/${repo}/tags?per_page=100")"; then
			candidates+="$(jq -r '.[].name' <<<"$tags_json")"$'\n'
		fi
	fi

	# GitLab
	if [[ "$provider" == "gitlab" ]]; then
		if tags_json="$(gitlab_api "https://gitlab.com/api/v4/projects/${repo//\//%2F}/repository/tags?per_page=100")"; then
			candidates+="$(jq -r '.[].name' <<<"$tags_json")"$'\n'
		fi
	fi

	# Фильтруем: убираем v, оставляем только цифры и точки
	printf '%s\n' "$candidates" \
		| sed -e 's/^v//' -e '/^[^0-9]/d' -e '/^$/d' \
		| sort -V \
		| tail -n1
}

# === ПОДДЕРЖКА GH_REPO ===
resolve_repo_and_provider() {
	local template="$1"
	local repo gh_repo distfiles

	gh_repo="$(template_var "$template" GH_REPO || true)"
	if [[ -n "$gh_repo" ]]; then
		repo="$gh_repo"
		if [[ "$gh_repo" =~ ^X11Libre/ ]]; then
			repo_provider="gitlab"
		else
			repo_provider="github"
		fi
		printf '%s' "$repo"
		return 0
	fi

	distfiles="$(template_var "$template" distfiles || true)"
	if [[ -n "$distfiles" ]]; then
		repo="$(repo_from_distfiles "$distfiles" || true)"
		if [[ -n "$repo" ]]; then
			if [[ "$repo" =~ ^X11Libre/ ]]; then
				repo_provider="gitlab"
			else
				repo_provider="github"
			fi
			printf '%s' "$repo"
			return 0
		fi
	fi

	return 1
}

# === СЧИТЫВАНИЕ ЧЕК-СУММ ===
checksums_for_urls() {
	local -a urls=("$@")
	local -a sums=()
	local idx=0

	for url in "${urls[@]}"; do
		[[ -n "$url" ]] || continue
		local artifact="$TMP_DIR/artifact_${idx}"
		curl -fsSL -L "$url" -o "$artifact"
		sums+=("$(sha256sum "$artifact" | awk '{print $1}')")
		idx=$((idx + 1))
	done

	printf '%s\n' "${sums[@]}"
}

checksum_literal() {
	local existing_line="$1"
	shift
	local -a sums=("$@")

	if [[ "${#sums[@]}" -eq 0 ]]; then
		return 1
	fi

	local joined
	joined="$(printf '%s ' "${sums[@]}")"
	joined="${joined% }"

	if [[ "${#sums[@]}" -gt 1 || "$existing_line" == *\"* ]]; then
		printf '"%s"' "$joined"
	else
		printf '%s' "$joined"
	fi
}

# === ЗАМЕНА В ФАЙЛЕ ===
replace_first_match() {
	local file="$1"
	local pattern="$2"
	local replacement="$3"
	awk -v p="$pattern" -v r="$replacement" '!done && $0 ~ p { print r; done=1; next } { print }' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}

replace_first_checksum() {
	local file="$1"
	local literal="$2"
	awk -v l="$literal" '
/^[[:space:]]*checksum=/ && !done {
	match($0, /^[[:space:]]*/)
	print substr($0, RSTART, RLENGTH) "checksum=" l
	done = 1
	next
}
{ print }
' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}

list_machine_arches() {
	local file="$1"
	awk '
/^[[:space:]]*case "\$XBPS_TARGET_MACHINE" in/ { in_case = 1; next }
in_case && /^[[:space:]]*esac/ { in_case = 0; next }
in_case && match($0, /^[[:space:]]*([A-Za-z0-9_+.-]+)\)[[:space:]]*$/, m) && m[1] != "*" {
	print m[1]
}
' "$file" | sort -u
}

arch_checksum_line() {
	local file="$1"
	local arch="$2"
	awk -v a="$arch" '
/^[[:space:]]*case "\$XBPS_TARGET_MACHINE" in/ { in_case = 1; next }
in_case && $0 ~ ("^[[:space:]]*" a "\\)[[:space:]]*$") { in_arch = 1; next }
in_case && in_arch && /^[[:space:]]*checksum=/ { print; exit }
in_case && /^[[:space:]]*esac/ { exit }
' "$file"
}

replace_arch_checksum() {
	local file="$1"
	local arch="$2"
	local literal="$3"
	awk -v a="$arch" -v l="$literal" '
/^[[:space:]]*case "\$XBPS_TARGET_MACHINE" in/ { in_case = 1 }
in_case && $0 ~ ("^[[:space:]]*" a "\\)[[:space:]]*$") { in_arch = 1; next }
in_case && in_arch && /^[[:space:]]*checksum=/ {
	match($0, /^[[:space:]]*/)
	print substr($0, RSTART, RLENGTH) "checksum=" l
	next
}
in_case && in_arch && /^[[:space:]]*;;/ { in_arch = 0 }
in_case && /^[[:space:]]*esac/ { in_case = 0 }
{ print }
' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}

# === ОСНОВНАЯ ЛОГИКА ===
process_template() {
	local template="$1"
	local pkgname version distfiles skip gh_repo repo latest_tag latest_version

	pkgname="$(template_var "$template" pkgname)"
	version="$(template_var "$template" version)"
	skip="$(template_var "$template" skip || true)"

	if [[ -z "$pkgname" || -z "$version" ]]; then
		echo "Skipping ${template}: missing pkgname/version"
		return 0
	fi

	if [[ -n "$skip" ]]; then
		echo "Skipping ${pkgname}: skip='${skip}'"
		return 0
	fi

	# Обновляем maintainer
	replace_first_match "$template" '^maintainer=' "$MAINTAINER_LINE"

	# Определяем репо
	if ! repo="$(resolve_repo_and_provider "$template")"; then
		echo "Skipping ${pkgname}: cannot determine repo from distfiles or GH_REPO"
		return 0
	fi

	# Получаем последний тег
	if ! latest_tag="$(latest_tag_for_repo "$repo")"; then
		echo "Failed to query ${repo_provider} for ${pkgname} (${repo})"
		return 1
	fi

	if [[ -z "$latest_tag" ]]; then
		echo "No tag found for ${pkgname} (${repo})"
		return 1
	fi

	latest_version="$latest_tag"

	# Защита от автообновления xlibre-* с версиями вида 25.0.0
	if [[ "$version" =~ ^[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] && [[ "$latest_version" =~ ^[0-9]+\.[0-9] ]]; then
		if printf '%s\n' "$version" "$latest_version" | sort -V | tail -n1 | grep -q "$version"; then
			echo "${pkgname}: version ${version} >= latest ${latest_version}, skipping auto-update"
			latest_version="$version"
		else
			echo "${pkgname}: would downgrade from ${version} to ${latest_version}, skipping"
			return 0
		fi
	fi

	if [[ "$version" == "$latest_version" ]]; then
		echo "${pkgname}: already at ${version}"
		return 0
	fi

	echo "${pkgname}: ${version} -> ${latest_version}"
	replace_first_match "$template" '^version=' "version=${latest_version}"

	# Обновляем checksum
	distfiles="$(template_var "$template" distfiles)"
	if grep -q 'case.*\$XBPS_TARGET_MACHINE' "$template"; then
		local arch
		mapfile -t arches < <(list_machine_arches "$template")
		for arch in "${arches[@]}"; do
			local arch_distfiles existing_line literal
			local -a urls sums

			arch_distfiles="$(template_var "$template" distfiles "$arch")"
			[[ -n "$arch_distfiles" ]] || continue
			read -r -a urls <<<"$arch_distfiles"
			mapfile -t sums < <(checksums_for_urls "${urls[@]}")
			existing_line="$(arch_checksum_line "$template" "$arch")"
			literal="$(checksum_literal "$existing_line" "${sums[@]}")"
			replace_arch_checksum "$template" "$arch" "$literal"
		done
	else
		local existing_line literal
		local -a urls sums

		read -r -a urls <<<"$distfiles"
		mapfile -t sums < <(checksums_for_urls "${urls[@]}")
		existing_line="$(grep -m1 '^[[:space:]]*checksum=' "$template" || true)"
		literal="$(checksum_literal "$existing_line" "${sums[@]}")"
		replace_first_checksum "$template" "$literal"
	fi
}

# === ЗАПУСК ===
mapfile -t templates < <(find "$PKG_DIR" -mindepth 2 -maxdepth 2 -type f -name template | sort)
if [[ "${#templates[@]}" -eq 0 ]]; then
	echo "No templates found under ${PKG_DIR}" >&2
	exit 1
fi

failures=0
for template in "${templates[@]}"; do
	if ! process_template "$template"; then
		failures=$((failures + 1))
	fi
done

if [[ "$failures" -gt 0 ]]; then
	echo "Updater failed for ${failures} template(s)" >&2
	exit 1
fi

echo "All templates updated successfully!"
