# office — docx/pptx/xlsx/pdf: LibreOffice (headless, current PPA), poppler, qpdf, ImageMagick, Office-metric fonts, Python and JS document libraries
# python-docx/pptx/openpyxl/pandas/pdfplumber/reportlab/markitdown; docx, pptxgenjs, exceljs via bun.
# shellcheck shell=bash

setup() {
  apt_install software-properties-common || return 1
  $SUDO add-apt-repository -y ppa:libreoffice/ppa >/dev/null 2>&1 && apt_stale # else Ubuntu's own release
  apt_install libreoffice-writer-nogui libreoffice-calc-nogui libreoffice-impress-nogui \
    poppler-utils qpdf imagemagick \
    fonts-liberation2 fonts-dejavu-core fonts-crosextra-carlito fonts-crosextra-caladea fonts-noto-core || return 1
  $SUDO "$(command -v uv)" pip install --system --break-system-packages -q \
    python-docx python-pptx openpyxl pandas pypdf pdfplumber reportlab defusedxml lxml \
    'markitdown[docx,pptx,xlsx,pdf]' || return 1
  local dir="$SHARE/office-js"
  mkdir -p "$dir" && [ -f "$dir/package.json" ] || printf '{"private":true}\n' > "$dir/package.json"
  (cd "$dir" && bun add docx pptxgenjs exceljs >/dev/null) || return 1
  # Global resolution for `node -e "require('docx')"` and scripts outside a project.
  $SUDO mkdir -p /usr/local/lib/node_modules && for p in docx pptxgenjs exceljs; do
    $SUDO ln -sfn "$dir/node_modules/$p" "/usr/local/lib/node_modules/$p"; done
  command -v soffice >/dev/null && command -v markitdown >/dev/null
}

status() { echo "libreoffice=$(ver soffice --version) markitdown=$(command -v markitdown >/dev/null && echo ok || echo missing)"; }
