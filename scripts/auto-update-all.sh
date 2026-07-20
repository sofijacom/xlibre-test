#!/bin/bash
# auto-update-all.sh — массовое обновление всех template в srcpkgs
# Запускать из любой директории — сам найдёт корень

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 🔧 Гарантированно переходим в корень репозитория
SCRIPT_DIR="$(dirname "$0")"
cd "$SCRIPT_DIR/.." || { echo -e "${RED}❌ Не могу перейти в корень репозитория${NC}"; exit 1; }

srcpkgs_dir="srcpkgs"
updated_count=0
declare -a updated_pkgs

# 🔍 Проверяем, существует ли srcpkgs
if [[ ! -d "$srcpkgs_dir" ]]; then
  echo -e "${RED}❌ Папка $srcpkgs_dir не найдена Текущая директория: $(pwd)${NC}"
  exit 1
fi

echo -e "${GREEN}🔄 Начинаем массовое обновление всех пакетов в $srcpkgs_dir/${NC}"

# 🔍 Отладка: сколько папок и template
echo -e "${BLUE}🔍 Найдено папок в $srcpkgs_dir: $(ls -1 "$srcpkgs_dir" | wc -l | xargs)${NC}"
echo -e "${YELLOW}📋 Первые 20 пакетов:${NC}"
ls -1 "$srcpkgs_dir" | head -20 | sed 's/^/   • /'
if [[ $(ls -1 "$srcpkgs_dir" | wc -l) -gt 20 ]]; then
  echo -e "   ${YELLOW}... и ещё $(($(ls -1 "$srcpkgs_dir" | wc -l) - 20))${NC}"
fi

# 🔁 Основной цикл
for pkgdir in "$srcpkgs_dir"/*/; do
  [[ -d "$pkgdir" ]] || continue
  pkgname=$(basename "$pkgdir")
  template="$pkgdir/template"

  # Проверяем наличие template
  if [[ ! -f "$template" ]]; then
    echo -e "   ${YELLOW}⚠️  Нет template — пропускаем $pkgname${NC}"
    continue
  fi

  echo -e "\n${BLUE}📦 Обрабатываем: $pkgname${NC}"

  # === 1. Извлекаем текущую версию ===
  if ! grep -q "^version=" "$template"; then
    echo -e "   ${YELLOW}⚠️  Нет поля version= — пропускаем${NC}"
    continue
  fi
  old_version=$(grep "^version=" "$template" | cut -d= -f2 | tr -d '"')
  echo -e "   ${YELLOW}Текущая версия: $old_version${NC}"

  # === 2. Извлекаем homepage и distfiles ===
  homepage=$(grep "^homepage=" "$template" | cut -d= -f2- | tr -d '"')
  distfiles_line=$(grep "^distfiles=" "$template" | sed 's/^distfiles="\(.*\)".*/\1/')
  distfiles=$(echo "$distfiles_line" | awk '{print $1}' | head -1)

  new_version=""

  # === 3. Попытка 1: GitHub Releases ===
  if [[ -n "$homepage" && "$homepage" == https://github.com/* ]] && [[ "$homepage" != *github.com/void-linux* ]]; then
    repo_path="${homepage#https://github.com/}"
    api_url="https://api.github.com/repos/$repo_path/releases/latest"
    echo -e "   ${YELLOW}🔍 Проверяем GitHub: $api_url${NC}"
    new_version=$(curl -s --fail "$api_url" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//') || true
  fi

  # === 4. Попытка 2: из distfiles (архив на GitHub) ===
  if [[ -z "$new_version" && -n "$distfiles" && "$distfiles" == *github.com* ]]; then
    if [[ "$distfiles" =~ /archive/(.+)\.tar\.gz ]]; then
      tag="${BASH_REMATCH[1]}"
      new_version="${tag#v}"
      echo -e "   ${YELLOW}🔍 Распознано из URL: $new_version${NC}"
    fi
  fi

  # === 5. Попытка 3: из имени файла (например, pkg-1.2.3.tar.gz) ===
  if [[ -z "$new_version" && -n "$distfiles" ]]; then
    filename=$(basename "$distfiles")
    if [[ "$filename" =~ -([0-9]+\.[0-9]+(\.[0-9]+)?([.-][a-zA-Z0-9]+)?)\.(tar|zip) ]]; then
      new_version="${BASH_REMATCH[1]}"
      echo -e "   ${YELLOW}🔍 Распознано из имени: $new_version${NC}"
    fi
  fi

  # === 6. Проверка результата ===
  if [[ -z "$new_version" ]]; then
    echo -e "   ${YELLOW}⚠️  Не удалось определить новую версию — пропускаем${NC}"
    continue
  fi

  if [[ "$new_version" == "$old_version" ]]; then
    echo -e "   ${GREEN}✅ Уже актуально: $old_version${NC}"
    continue
  fi

  echo -e "   ${GREEN}🆕 Найдена новая версия: $new_version${NC}"

  # === 7. Обновляем версию в template ===
  sed -i "s/^version=.*/version=\"$new_version\"/" "$template"
  echo -e "   ${GREEN}✅ Версия обновлена${NC}"

  # === 8. Обновляем distfiles и checksum ===
  new_distfiles=$(echo "$distfiles_line" | sed "s/\${version}/$new_version/g; s/\$version/$new_version/g")
  archive_url=$(echo "$new_distfiles" | awk '{print $1}' | tr -d '"')

  tmpdir="/tmp/autoupdate-$pkgname"
  mkdir -p "$tmpdir" || { echo -e "   ${RED}❌ Не могу создать папку $tmpdir${NC}"; continue; }
  cd "$tmpdir" || { echo -e "   ${RED}❌ Не могу перейти в $tmpdir${NC}"; continue; }

  filename=$(basename "$archive_url")
  echo -e "   ${YELLOW}⬇️ Скачиваю $filename...${NC}"
  if ! curl -fL -o "$filename" "$archive_url"; then
    echo -e "   ${RED}❌ Ошибка загрузки — откатываем версию${NC}"
    sed -i "s/^version=.*/version=\"$old_version\"/" "$template"
    continue
  fi

  new_checksum=$(sha256sum "$filename" | awk '{print $1}')
  sed -i "s/^checksum=.*/checksum=\"$new_checksum\"/" "$template"
  echo -e "   ${GREEN}✅ Checksum обновлён${NC}"

  echo -e "   ${GREEN}🎉 $pkgname обновлён: $old_version → $new_version${NC}"
  git diff "$template" || true

  updated_count=$((updated_count + 1))
  updated_pkgs+=("$pkgname: $old_version → $new_version")
done

# === 9. Итог ===
echo -e "\n${GREEN}✅ Готово: обновлено $updated_count пакетов${NC}"
if [[ $updated_count -gt 0 ]]; then
  echo -e "${BLUE}📝 Список обновлённых:${NC}"
  for pkg in "${updated_pkgs[@]}"; do
    echo "   • $pkg"
  done
else
  echo -e "${YELLOW}ℹ️  Нет пакетов, требующих обновления${NC}"
fi
