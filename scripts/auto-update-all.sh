#!/bin/bash
# auto-update-all.sh — массовое обновление шаблонов
# Поддерживает GitHub releases, tags, отладку

# set -euo pipefail

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

# Спец-пакеты
declare -A skip_pkgs=(
  ["xlibre-repo"]=1
  ["xlibre-xf86-input-evdev-devel"]=1
  ["workflow-helper"]=1
)

if [[ ! -d "$srcpkgs_dir" ]]; then
  echo -e "${RED}❌ Папка $srcpkgs_dir не найдена${NC}"
  exit 1
fi

total_dirs=()
for dir in "$srcpkgs_dir"/*/; do
  [[ -d "$dir" ]] && [[ ! -L "$dir" ]] && total_dirs+=("$dir")
done
total=${#total_dirs[@]}
i=0

echo -e "${GREEN}🔄 Начинаем обновление — найдено: $total пакетов${NC}"

for pkgdir in "$srcpkgs_dir"/*/; do
  pkgname=$(basename "$pkgdir")
  [[ -d "$pkgdir" ]] || continue

  if [[ -L "$pkgdir" ]]; then
    echo -e "\n${YELLOW}🔗 [$((++i))/$total] $pkgname — симлинк — пропускаем${NC}"
    continue
  fi
  ((i++))

  if [[ -n "${skip_pkgs[$pkgname]:-}" ]]; then
    echo -e "\n${YELLOW}🛠 [$i/$total] $pkgname — исключён — пропускаем${NC}"
    continue
  fi

  template="$pkgdir/template"
  if [[ ! -f "$template" ]]; then
    echo -e "\n${YELLOW}⚠️  [$i/$total] $pkgname — нет template — пропускаем${NC}"
    continue
  fi

  echo -e "\n${BLUE}📦 [$i/$total] Обрабатываем: $pkgname${NC}"

  old_version=$(grep "^version=" "$template" | cut -d= -f2 | tr -d '"' | sed 's/ //g' || true)
  if [[ -z "$old_version" ]]; then
    echo -e "   ${YELLOW}⚠️  Нет version= — пропускаем${NC}"
    continue
  fi
  echo -e "   ${YELLOW}Текущая версия: $old_version${NC}"

  homepage=$(grep "^homepage=" "$template" | cut -d= -f2- | tr -d '"' | sed 's/ //g' || true)
  distfiles_line=$(grep "^distfiles=" "$template" | sed 's/^distfiles="\(.*\)".*/\1/' || true)
  distfiles=$(echo "$distfiles_line" | awk '{print $1}' | sed 's/ //g' || true)

  new_version=""

  # === 1. Попытка: GitHub Releases ===
  if [[ -n "$homepage" && "$homepage" == https://github.com/* ]] && [[ "$homepage" != *github.com/void-linux* ]] && [[ "$homepage" != *wiki* ]]; then
    repo_path="${homepage#https://github.com/}"
    repo_path="${repo_path%/}"
    api_url="https://api.github.com/repos/$repo_path/releases/latest"
    echo -e "   ${YELLOW}🔧 Запрашиваем: $api_url${NC}"

    response=$(curl -s --fail -H "Accept: application/vnd.github.v3+json" "$api_url" || true)
    if [[ -z "$response" ]]; then
      echo -e "   ${RED}❌ API: пустой ответ — возможно, нет релизов${NC}"
    else
      echo -e "   ${YELLOW}🔍 Ответ получен (фрагмент): $(echo "$response" | head -c 100)...${NC}"
      tag_name=$(echo "$response" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//' | sed 's/ .*//' || true)
      if [[ -n "$tag_name" ]]; then
        echo -e "   ${GREEN}🏷️  Найден тег: $tag_name${NC}"
        if [[ "$tag_name" =~ ^[0-9]+\.[0-9] ]]; then
          new_version="$tag_name"
          echo -e "   ${GREEN}✅ Версия принята: $new_version${NC}"
        else
          echo -e "   ${YELLOW}⚠️  Тег не цифровой: $tag_name — пропускаем${NC}"
        fi
      else
        echo -e "   ${YELLOW}⚠️  В ответе нет tag_name — возможно, нет релизов${NC}"
      fi
    fi
  fi

  # === 2. Попытка: последний тег в репозитории ===
  if [[ -z "$new_version" && -n "$homepage" && "$homepage" == https://github.com/* ]]; then
    repo_path="${homepage#https://github.com/}"
    repo_path="${repo_path%/}"
    tags_url="https://api.github.com/repos/$repo_path/tags?per_page=1"
    echo -e "   ${YELLOW}🔍 Проверяем последний тег: $tags_url${NC}"

    tag_response=$(curl -s --fail -H "Accept: application/vnd.github.v3+json" "$tags_url" || true)
    if [[ -n "$tag_response" ]]; then
      latest_tag=$(echo "$tag_response" | grep '"name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//' | sed 's/ .*//' || true)
      if [[ -n "$latest_tag" ]]; then
        echo -e "   ${GREEN}🏷️  Последний тег: $latest_tag${NC}"

        # Нормализуем тег: xorg-25.0 → 25.0, RELEASE-25-1 → 25.1
        normalized_tag=$(echo "$latest_tag" | sed -E 's/[^0-9.]+([0-9]+\.[0-9]+.*)/\1/' | sed -E 's/[^0-9.]//g' | sed -E 's/\.$//' || true)
        if [[ "$normalized_tag" =~ ^[0-9]+\.[0-9] ]]; then
          new_version="$normalized_tag"
          echo -e "   ${GREEN}✅ Версия нормализована: $new_version${NC}"
        elif [[ "$latest_tag" =~ ^[0-9]+\.[0-9] ]]; then
          new_version="$latest_tag"
          echo -e "   ${GREEN}✅ Версия принята: $new_version${NC}"
        else
          echo -e "   ${YELLOW}⚠️  Не удалось нормализовать: $latest_tag${NC}"
        fi
      else
        echo -e "   ${YELLOW}⚠️  Нет тегов в репозитории${NC}"
      fi
    else
      echo -e "   ${RED}❌ Ошибка при запросе тегов${NC}"
    fi
  fi

  # === 3. Попытка: из distfiles (GitHub archive) ===
  if [[ -z "$new_version" && -n "$distfiles" && "$distfiles" == *github.com* ]]; then
    if [[ "$distfiles" =~ /archive/(.+)\.tar\.gz ]]; then
      tag="${BASH_REMATCH[1]}"
      ver="${tag#v}"
      ver="${ver%.tar.gz}"
      if [[ "$ver" =~ ^[0-9]+\.[0-9] ]]; then
        new_version="$ver"
        echo -e "   ${GREEN}🔍 Распознано из URL: $new_version${NC}"
      fi
    fi
  fi

  # === 4. Попытка: из имени файла ===
  if [[ -z "$new_version" && -n "$distfiles" ]]; then
    filename=$(basename "$distfiles")
    if [[ "$filename" =~ -([0-9]+\.[0-9]+(\.[0-9]+)?([.-][a-zA-Z0-9]+)?)\.(tar|zip) ]]; then
      ver="${BASH_REMATCH[1]}"
      if [[ "$ver" =~ ^[0-9]+\.[0-9] ]]; then
        new_version="$ver"
        echo -e "   ${GREEN}🔍 Распознано из имени: $new_version${NC}"
      fi
    fi
  fi

  # === 5. Проверка ===
  if [[ -z "$new_version" ]]; then
    echo -e "   ${YELLOW}⚠️  Не удалось определить версию — пропускаем${NC}"
    continue
  fi

  if [[ "$new_version" == "$old_version" ]]; then
    echo -e "   ${GREEN}✅ Уже актуально: $old_version${NC}"
    continue
  fi

  # === 6. Обновляем version ===
  if sed -i "s|^version=.*|version=\"$new_version\"|" "$template"; then
    echo -e "   ${GREEN}✅ Версия обновлена: $old_version → $new_version${NC}"
  else
    echo -e "   ${RED}❌ Ошибка при обновлении version — пропускаем${NC}"
    continue
  fi

  # === 7. Обновляем distfiles ===
  new_distfiles="$distfiles_line"
  new_distfiles="${new_distfiles//\$\{version\}/$new_version}"
  new_distfiles="${new_distfiles//\$version/$new_version}"
  new_distfiles="${new_distfiles//\$\{pkgname\}/$pkgname}"
  new_distfiles="${new_distfiles//\$pkgname/$pkgname}"
  new_distfiles=$(echo "$new_distfiles" | sed 's|//+|/|g; s|https:/|https://|g')

  archive_url=$(echo "$new_distfiles" | awk '{print $1}' | tr -d '"' | sed 's/ //g' || true)
  if [[ -z "$archive_url" ]]; then
    echo -e "   ${RED}❌ Не удалось сформировать URL — откатываем${NC}"
    sed -i "s|^version=.*|version=\"$old_version\"|" "$template"
    continue
  fi

  echo -e "   ${YELLOW}🔗 URL: $archive_url${NC}"

  if ! curl -s --fail -o /dev/null -I "$archive_url"; then
    echo -e "   ${RED}❌ URL недоступен — откатываем${NC}"
    sed -i "s|^version=.*|version=\"$old_version\"|" "$template"
    continue
  fi

  # === 8. Скачивание и checksum ===
  tmpdir="/tmp/autoupdate-$pkgname"
  mkdir -p "$tmpdir" || { echo -e "   ${RED}❌ Не могу создать папку${NC}"; continue; }
  cd "$tmpdir" || continue

  filename=$(basename "$archive_url")
  echo -e "   ${YELLOW}⬇️ Скачиваю $filename...${NC}"

  if ! curl -fL -o "$filename" "$archive_url"; then
    echo -e "   ${RED}❌ Ошибка загрузки — откатываем${NC}"
    sed -i "s|^version=.*|version=\"$old_version\"|" "$template"
    continue
  fi

  new_checksum=$(sha256sum "$filename" | awk '{print $1}' || true)
  if [[ -z "$new_checksum" ]]; then
    echo -e "   ${RED}❌ Ошибка хеширования — откатываем${NC}"
    sed -i "s|^version=.*|version=\"$old_version\"|" "$template"
    continue
  fi

  if sed -i "s|^checksum=.*|checksum=\"$new_checksum\"|" "$template"; then
    echo -e "   ${GREEN}✅ Checksum обновлён${NC}"
  else
    echo -e "   ${RED}❌ Ошибка checksum — откатываем${NC}"
    sed -i "s|^version=.*|version=\"$old_version\"|" "$template"
    continue
  fi

  echo -e "   ${GREEN}🎉 Успешно: $old_version → $new_version${NC}"
  updated_count=$((updated_count + 1))
  updated_pkgs+=("$pkgname: $old_version → $new_version")
done

# === 9. Итог ===
echo -e "\n${GREEN}✅ Готово: обработано $total пакетов${NC}"
echo -e "${GREEN}🔄 Попыток: $((i))${NC}"
echo -e "${GREEN}🎉 Успешно обновлено: $updated_count${NC}"

if [[ $updated_count -gt 0 ]]; then
  echo -e "${BLUE}📝 Обновлены:${NC}"
  for pkg in "${updated_pkgs[@]}"; do
    echo "   • $pkg"
  done
else
  echo -e "${YELLOW}ℹ️  Нет обновлений${NC}"
fi
