#!/bin/bash
# auto-update-all.sh — массовое обновление всех template в srcpkgs
# Полностью отказоустойчивый, с защитой от симлинков, sed-ошибок и 404

# set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 🔧 Переходим в корень репозитория
SCRIPT_DIR="$(dirname "$0")"
cd "$SCRIPT_DIR/.." || { echo -e "${RED}❌ Не могу перейти в корень репозитория${NC}"; exit 1; }

srcpkgs_dir="srcpkgs"
updated_count=0
declare -a updated_pkgs

# 🔍 Проверяем наличие srcpkgs
if [[ ! -d "$srcpkgs_dir" ]]; then
  echo -e "${RED}❌ Папка $srcpkgs_dir не найдена. Текущая директория: $(pwd)${NC}"
  exit 1
fi

# 📊 Считаем количество подпапок (не симлинков)
total_dirs=()
for dir in "$srcpkgs_dir"/*/; do
  [[ -d "$dir" ]] && [[ ! -L "$dir" ]] && total_dirs+=("$dir")
done
total=${#total_dirs[@]}
i=0

echo -e "${GREEN}🔄 Начинаем массовое обновление всех пакетов в $srcpkgs_dir/${NC}"
echo -e "${BLUE}🔍 Найдено реальных папок: $total${NC}"

# 🔁 Основной цикл
for pkgdir in "$srcpkgs_dir"/*/; do
  [[ -d "$pkgdir" ]] || continue
  [[ -L "$pkgdir" ]] && { echo -e "\n${YELLOW}🔗 [$((++i))/$total] $(basename "$pkgdir") — симлинк — пропускаем${NC}"; continue; }
  ((i++))
  pkgname=$(basename "$pkgdir")
  template="$pkgdir/template"

  # Проверяем наличие template
  if [[ ! -f "$template" ]]; then
    echo -e "\n${YELLOW}⚠️  [$i/$total] $pkgname — нет template — пропускаем${NC}"
    continue
  fi

  echo -e "\n${BLUE}📦 [$i/$total] Обрабатываем: $pkgname${NC}"

  # === 1. Проверяем version ===
  if ! grep -q "^version=" "$template"; then
    echo -e "   ${YELLOW}⚠️  Нет version= — пропускаем${NC}"
    continue
  fi
  old_version=$(grep "^version=" "$template" | cut -d= -f2 | tr -d '"' | sed 's/ //g' || true)
  if [[ -z "$old_version" ]]; then
    echo -e "   ${YELLOW}⚠️  Пустая версия — пропускаем${NC}"
    continue
  fi
  echo -e "   ${YELLOW}Текущая версия: $old_version${NC}"

  # === 2. Извлекаем данные ===
  homepage=$(grep "^homepage=" "$template" | cut -d= -f2- | tr -d '"' | sed 's/ //g' || true)
  distfiles_line=$(grep "^distfiles=" "$template" | sed 's/^distfiles="\(.*\)".*/\1/' || true)
  distfiles=$(echo "$distfiles_line" | awk '{print $1}' | head -1 | sed 's/ //g' || true)

  new_version=""

  # === 3. Попытка 1: GitHub Releases ===
  if [[ -n "$homepage" && "$homepage" == https://github.com/* ]] && [[ "$homepage" != *github.com/void-linux* ]] && [[ "$homepage" != *github.com/*/wiki* ]]; then
    repo_path="${homepage#https://github.com/}"
    repo_path="${repo_path%/}"  # убираем trailing slash
    api_url="https://api.github.com/repos/$repo_path/releases/latest"
    echo -e "   ${YELLOW}🔍 Проверяем GitHub: $api_url${NC}"
    new_version=$(curl -s --fail -H "Accept: application/vnd.github.v3+json" "$api_url" | \
      grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//' | sed 's/ .*//' || true)
  fi

  # === 4. Попытка 2: из distfiles (GitHub archive) ===
  if [[ -z "$new_version" && -n "$distfiles" && "$distfiles" == *github.com* ]]; then
    if [[ "$distfiles" =~ /archive/(.+)\.tar\.gz ]]; then
      tag="${BASH_REMATCH[1]}"
      new_version="${tag#v}"
      new_version="${new_version%.tar.gz}"
      echo -e "   ${YELLOW}🔍 Распознано из URL: $new_version${NC}"
    fi
  fi

  # === 5. Попытка 3: из имени файла (pkg-1.2.3.tar.gz) ===
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

  # === 7. Обновляем version в template (безопасный sed) ===
  if sed -i "s|^version=.*|version=\"$new_version\"|" "$template"; then
    echo -e "   ${GREEN}✅ Версия обновлена${NC}"
  else
    echo -e "   ${RED}❌ Ошибка при обновлении version — пропускаем${NC}"
    continue
  fi

  # === 8. Обновляем distfiles и checksum ===
  # Убираем ${pkgname} и $pkgname из строки, чтобы не дублировать
  new_distfiles=$(echo "$distfiles_line" | \
    sed "s|\${version}|$new_version|g; s|\$version|$new_version|g; s|\${pkgname}||g; s|\$pkgname||g" | \
    sed 's|//+|/|g' | sed 's|https:/|https://|g')

  archive_url=$(echo "$new_distfiles" | awk '{print $1}' | tr -d '"' | sed 's/ //g' || true)
  if [[ -z "$archive_url" ]]; then
    echo -e "   ${RED}❌ Не удалось сформировать URL — откатываем версию${NC}"
    sed -i "s|^version=.*|version=\"$old_version\"|" "$template"
    continue
  fi

  echo -e "   ${YELLOW}🔗 URL архива: $archive_url${NC}"

  # Проверим, доступен ли URL
  if ! curl -s --fail -o /dev/null -I "$archive_url"; then
    echo -e "   ${RED}❌ URL недоступен (404) — откатываем версию${NC}"
    sed -i "s|^version=.*|version=\"$old_version\"|" "$template"
    continue
  fi

  # Скачиваем
  tmpdir="/tmp/autoupdate-$pkgname"
  mkdir -p "$tmpdir" || { echo -e "   ${RED}❌ Не могу создать $tmpdir — пропускаем${NC}"; continue; }
  cd "$tmpdir" || { echo -e "   ${RED}❌ Не могу перейти в $tmpdir — пропускаем${NC}"; continue; }

  filename=$(basename "$archive_url")
  echo -e "   ${YELLOW}⬇️ Скачиваю $filename...${NC}"

  if ! curl -fL --fail -o "$filename" "$archive_url"; then
    echo -e "   ${RED}❌ Ошибка загрузки — откатываем версию${NC}"
    sed -i "s|^version=.*|version=\"$old_version\"|" "$template"
    continue
  fi

  if [[ ! -f "$filename" ]]; then
    echo -e "   ${RED}❌ Файл не создан — откатываем${NC}"
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
    echo -e "   ${RED}❌ Ошибка обновления checksum — откатываем${NC}"
    sed -i "s|^version=.*|version=\"$old_version\"|" "$template"
    continue
  fi

  echo -e "   ${GREEN}🎉 $pkgname: $old_version → $new_version${NC}"
  git diff "$template" || true

  updated_count=$((updated_count + 1))
  updated_pkgs+=("$pkgname: $old_version → $new_version")
done

# === 9. Итог ===
echo -e "\n${GREEN}✅ Готово: обработано $total пакетов${NC}"
echo -e "${GREEN}🔄 Попыток обновить: $((i))${NC}"
echo -e "${GREEN}🎉 Успешно обновлено: $updated_count${NC}"

if [[ $updated_count -gt 0 ]]; then
  echo -e "${BLUE}📝 Список обновлённых:${NC}"
  for pkg in "${updated_pkgs[@]}"; do
    echo "   • $pkg"
  done
else
  echo -e "${YELLOW}ℹ️  Нет пакетов, требующих обновления${NC}"
fi
