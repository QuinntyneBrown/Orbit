/**
 * build-pdf.mjs
 * Converts a Markdown resume file to PDF using Playwright Chromium.
 *
 * Usage: node scripts/build-pdf.mjs <input.md>
 *
 * Requirements:
 *   - templates/resume.html (must contain {{CONTENT}} placeholder)
 *   - marked (npm package)
 *   - playwright (npm package)
 */

import { readFileSync, existsSync, mkdirSync } from 'fs';
import { resolve, basename, extname, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const repoRoot = resolve(__dirname, '..');

// --- Validate input argument ---
const inputArg = process.argv[2];
if (!inputArg) {
  console.error('Usage: node scripts/build-pdf.mjs <input.md>');
  process.exit(1);
}

const inputPath = resolve(inputArg);
if (!existsSync(inputPath)) {
  console.error(`Input file not found: ${inputPath}`);
  process.exit(1);
}

// --- Check template exists ---
const templatePath = resolve(repoRoot, 'templates', 'resume.html');
if (!existsSync(templatePath)) {
  console.error(`Template not found: ${templatePath}`);
  console.error('Place your HTML template at templates/resume.html with a {{CONTENT}} placeholder.');
  process.exit(1);
}

// --- Convert Markdown to HTML ---
let marked;
try {
  const markedModule = await import('marked');
  marked = markedModule.marked ?? markedModule.default;
} catch (err) {
  console.error('Failed to import "marked". Run: npm install');
  console.error(err.message);
  process.exit(1);
}

const markdownSource = readFileSync(inputPath, 'utf8');
const renderedHtml = marked.parse(markdownSource);

// --- Inject into template ---
const templateHtml = readFileSync(templatePath, 'utf8');
const fullHtml = templateHtml.replace('{{CONTENT}}', renderedHtml);

// --- Determine output path ---
const nameWithoutExt = basename(inputPath, extname(inputPath));
const exportsDir = resolve(repoRoot, 'exports');
if (!existsSync(exportsDir)) {
  mkdirSync(exportsDir, { recursive: true });
}
const outputPath = resolve(exportsDir, `${nameWithoutExt}.pdf`);

// --- Launch Playwright and render PDF ---
let chromium;
try {
  const playwright = await import('playwright');
  chromium = playwright.chromium ?? playwright.default?.chromium;
} catch (err) {
  console.error('Failed to import "playwright". Run: npm install && npx playwright install chromium');
  console.error(err.message);
  process.exit(1);
}

let browser;
try {
  browser = await chromium.launch();
  const page = await browser.newPage();

  await page.setContent(fullHtml, { waitUntil: 'networkidle' });

  await page.pdf({
    path: outputPath,
    format: 'A4',
    margin: {
      top: '12mm',
      right: '16mm',
      bottom: '12mm',
      left: '16mm',
    },
    printBackground: true,
  });

  console.log(`PDF written to: ${outputPath}`);
} catch (err) {
  console.error('PDF generation failed:', err.message);
  process.exit(1);
} finally {
  if (browser) {
    await browser.close();
  }
}

process.exit(0);
