#!/bin/bash
#set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(dirname "$0")"
cd "$SCRIPT_DIR/.." || { echo -e "${RED}❌ Не могу перейти в корень${NC}"; exit 1; }

srcpkgs_dir="srcpkgs"
updated_count=0
declare -a updated_pkgs

# Исключения
declare -A skip_pkgs=(
  ["xlibre-repo"]=1
  ["xlibre-xf86-input-evdev-devel"]=1
  ["workflow-helper"]=1
)

# Функция: извлекает версию из тега (например, xlibre-xf86-video-amdgpu-25.1.1 → 25.1.1)
extract_version() {
  local tag="$1"
  # Убираем префикс вроде xlibre-, xorg-, xo-, release-, v
  echo "$tag" | sed -E 's/^(xlibre-|xorg-|xo-|release-|v|util-macros-)//i' | sed 's/_/./g'
}

# Функция: проверяет, выглядит ли строка как цифровая версия (25.1.1, 1.20.2 и т.д.)
is_valid_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

# Функция: получает последний тег из репозитория
get_latest_tag() {
  local repo="$1"
  local tag_url="https://api.github.com/repos/$repo/tags"
  local tag_data
  tag_data=$(curl -s -H "Accept: application/vnd.github.v3+json" "$tag_url" | jq -r '.[0].name' 2>/dev/null || echo "")
  if [[ -n "$tag_data" && "$tag_data" != "null" ]]; then
    echo "$tag_data"
  else
    echo ""
  fi
}

# Функция: получает последний релиз
get_latest_release_tag() {
  local repo="$1"
  local rel_url="https://api.github.com/repos/$repo/releases/latest"
  local tag_name
  tag_name=$(curl -s -H "Accept: application/vnd.github.v3+json" "$rel_url" | jq -r '.tag_name' 2>/dev/null || echo "")
  if [[ -n "$tag_name" && "$tag_name" != "null" ]]; then
    echo "$tag_name"
  else
    echo ""
  fi
}

# Проход по папкам
for dir in "$srcpkgs_dir"/*/; do
  pkg_name=$(basename "$dir")
  [[ -d "$dir" ]] || continue
  [[ -L "$dir" ]] && continue
  [[ -v skip_pkgs["$pkg_name"] ]] && { echo -e "🛠 [$pkg_name] — исключён — пропускаем"; continue; }

  template_file="$dir/template"
  [[ -f "$template_file" ]] || { echo -e "${RED}❌ Нет template: $template_file${NC}"; continue; }

  current_version=$(grep -E "^version=" "$template_file" | cut -d= -f2 | tr -d '"')
  [[ -n "$current_version" ]] || { echo -e "${YELLOW}⚠️  Нет версии в $pkg_name${NC}"; continue; }

  echo -e "📦 Обрабатываем: $pkg_name"
  echo -e "   Текущая версия: $current_version"

  # Определяем репозиторий (можно улучшить через _template или _gitrepo)
  case "$pkg_name" in
    xlibre-xf86-input-*|xlibre-xf86-video-*|xlibre-util-macros|xlibre-xorgproto)
      repo_name=$(echo "$pkg_name" | sed 's/^xlibre-//')
      repo_owner="X11Libre"
      if [[ "$repo_name" == "util-macros" || "$repo_name" == "xorgproto" ]]; then
        repo_owner="X11Libre"
        repo_name="mirror.fdo.${repo_name}"
      fi
      repo_full="$repo_owner/$repo_name"
      ;;
    xlibre-xserver*|xlibre-apps|xlibre-minimal|xlibre-input-drivers|xlibre-video-drivers)
      repo_full="X11Libre/xserver"
      ;;
    *)
      echo -e "${YELLOW}⚠️  Неизвестный пакет — пропускаем${NC}"
      continue
      ;;
  esac

  latest_tag=""
  # Сначала пытаемся взять из релизов
  latest_tag=$(get_latest_release_tag "$repo_full")
  if [[ -n "$latest_tag" ]]; then
    echo -e "   🏷️  Найден релизный тег: $latest_tag"
  else
    # Если релизов нет — берём последний тег
    latest_tag=$(get_latest_tag "$repo_full")
    if [[ -n "$latest_tag" ]]; then
      echo -e "   🏷️  Последний тег: $latest_tag"
    else
      echo -e "${YELLOW}   ⚠️  Не удалось получить тег${NC}"
      continue
    fi
  fi

  # Извлекаем чистую версию
  candidate_version=$(extract_version "$latest_tag")
  if ! is_valid_version "$candidate_version"; then
    echo -e "${YELLOW}   ⚠️  Не цифровая версия: $candidate_version — пропускаем${NC}"
    continue
  fi

  if [[ "$candidate_version" == "$current_version" ]]; then
    echo -e "   ✅ Уже актуально: $current_version"
    continue
  fi

  # Обновляем шаблон
  sed -i "s/^version=.*/version=\"$candidate_version\"/" "$template_file"
  echo -e "${GREEN}   ✅ Версия обновлена: $current_version → $candidate_version${NC}"

  # Обновляем URL (если есть)
  new_url="https://github.com/$repo_owner/${repo_name}/archive/refs/tags/$latest_tag.tar.gz"
  if grep -q "^distfiles=" "$template_file"; then
    sed -i "s|^distfiles=.*|distfiles=\"$new_url\"|" "$template_file"
  else
    sed -i "/^version=.*/a distfiles=\"$new_url\"" "$template_file"
  fi

  updated_count=$((updated_count + 1))
  updated_pkgs+=("$pkg_name")
done

echo -e "${GREEN}✅ Готово: обработано $((updated_count + $(echo ${#skip_pkgs[@]} + $(ls -1 "$srcpkgs_dir"/*/ | wc -l)) )) пакетов${NC}"
echo -e "${GREEN}🎉 Успешно обновлено: $updated_count${NC}"
if [[ $updated_count -gt 0 ]]; then
  echo -e "${BLUE}📝 Изменённые пакеты:${NC}"
  printf '  - %s\n' "${updated_pkgs[@]}"
fi
