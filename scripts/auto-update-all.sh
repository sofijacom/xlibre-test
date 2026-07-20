#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(dirname "$0")"
cd "$SCRIPT_DIR/.." || { echo -e "${RED}❌ Не могу перейти в корень репозитория${NC}"; exit 1; }

srcpkgs_dir="srcpkgs"
updated_count=0
declare -a updated_pkgs

# Список пакетов, которые НЕ нужно обновлять
declare -A skip_pkgs=(
  ["xlibre-apps"]=1
  ["xlibre-minimal"]=1
  ["xlibre-input-drivers"]=1
  ["xlibre-video-drivers"]=1
  ["xlibre-repo"]=1
  ["workflow-helper"]=1
  # Devel-пакеты — генерируются автоматически
  ["xlibre-xf86-input-evdev-devel"]=1
  ["xlibre-xf86-input-libinput-devel"]=1
  ["xlibre-xf86-input-synaptics-devel"]=1
  ["xlibre-xf86-input-wacom-devel"]=1
  ["xlibre-xf86-input-joystick-devel"]=1
  ["xlibre"]=1
)

# Функция: извлекает чистую версию из тега (например, 25.2.1)
extract_version() {
  local tag="$1"
  echo "$tag" | \
    sed -E 's/^(xlibre-|xorg-|xo-|release-|v|xserver-|xorgproto-|util-macros-|xf86-input-|xf86-video-)//i' | \
    sed 's/_/./g'
}

# Функция: проверяет, выглядит ли строка как цифровая версия (1.20.2, 25.1.0 и т.д.)
is_valid_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

# Функция: получает последний релиз (tag_name)
get_latest_release_tag() {
  local repo="$1"
  local url="https://api.github.com/repos/$repo/releases/latest"
  curl -s -H "Accept: application/vnd.github.v3+json" "$url" | \
    jq -r '.tag_name // empty' 2>/dev/null || echo ""
}

# Функция: получает последний тег (если релизов нет)
get_latest_tag() {
  local repo="$1"
  local url="https://api.github.com/repos/$repo/tags?per_page=1"
  curl -s -H "Accept: application/vnd.github.v3+json" "$url" | \
    jq -r '.[0].name // empty' 2>/dev/null || echo ""
}

# Проход по папкам
for dir in "$srcpkgs_dir"/*/; do
  pkg_name=$(basename "$dir")
  [[ -d "$dir" ]] || continue
  [[ -L "$dir" ]] && continue  # Пропускаем симлинки
  [[ -v skip_pkgs["$pkg_name"] ]] && { echo -e "🛠 [$pkg_name] — исключён — пропускаем"; continue; }

  template_file="$dir/template"
  [[ -f "$template_file" ]] || { echo -e "${RED}❌ Нет template: $template_file${NC}"; continue; }

  current_version=$(grep -E "^version=" "$template_file" | cut -d= -f2 | tr -d '"')
  [[ -n "$current_version" ]] || { echo -e "${YELLOW}⚠️  Нет версии в $pkg_name${NC}"; continue; }

  echo -e "📦 Обрабатываем: $pkg_name"
  echo -e "   Текущая версия: $current_version"

  # Определяем репозиторий
  repo_full=""
  case "$pkg_name" in
    xlibre-xf86-input-*|xlibre-xf86-video-*)
      repo_name=$(echo "$pkg_name" | sed 's/^xlibre-//')
      repo_full="X11Libre/$repo_name"
      ;;
    xlibre-util-macros)
      repo_full="X11Libre/mirror.fdo.xorg-macros"
      ;;
    xlibre-xorgproto)
      repo_full="X11Libre/mirror.fdo.xorgproto"
      ;;
    xlibre-xserver*|xlibre-xserver-common|xlibre-xserver-devel|xlibre-xserver-xephyr|xlibre-xserver-xnest|xlibre-xserver-xvfb)
      repo_full="X11Libre/xserver"
      ;;
    *)
      echo -e "${YELLOW}⚠️  Неизвестный пакет — пропускаем${NC}"
      continue
      ;;
  esac

  # Получаем последний тег
  latest_tag=""
  latest_tag=$(get_latest_release_tag "$repo_full")
  if [[ -z "$latest_tag" ]]; then
    latest_tag=$(get_latest_tag "$repo_full")
  fi

  if [[ -z "$latest_tag" ]]; then
    echo -e "${YELLOW}   ⚠️  Не удалось получить тег${NC}"
    continue
  fi

  echo -e "   🏷️  Найден тег: $latest_tag"

  # Извлекаем версию
  candidate_version=$(extract_version "$latest_tag")
  if ! is_valid_version "$candidate_version"; then
    echo -e "${YELLOW}   ⚠️  Не цифровая версия: $candidate_version — пропускаем${NC}"
    continue
  fi

  # Сравниваем
  if [[ "$candidate_version" == "$current_version" ]]; then
    echo -e "   ✅ Уже актуально: $current_version"
    continue
  fi

  # Обновляем version в template
  sed -i "s/^version=.*/version=\"$candidate_version\"/" "$template_file"
  echo -e "${GREEN}   ✅ Версия обновлена: $current_version → $candidate_version${NC}"

  # Формируем URL архива
  new_url="https://github.com/$repo_full/archive/refs/tags/$latest_tag.tar.gz"

  # Обновляем distfiles
  if grep -q "^distfiles=" "$template_file"); then
    sed -i "s|^distfiles=.*|distfiles=\"$new_url\"|" "$template_file"
  else
    sed -i "/^version=.*/a distfiles=\"$new_url\"" "$template_file"
  fi

  updated_count=$((updated_count + 1))
  updated_pkgs+=("$pkg_name")
done

echo -e "${GREEN}✅ Готово: обработано $(ls -1 "$srcpkgs_dir"/*/ | wc -l) пакетов${NC}"
echo -e "${GREEN}🎉 Успешно обновлено: $updated_count${NC}"
if [[ $updated_count -gt 0 ]]; then
  echo -e "${BLUE}📝 Изменённые пакеты:${NC}"
  printf '  - %s\n' "${updated_pkgs[@]}"
fi
