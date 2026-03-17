import fs from 'node:fs';
import path from 'node:path';

const TARGET_DIR = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.resolve('tmp/icon_proposals');

const files = fs.readdirSync(TARGET_DIR)
  .filter((fileName) => fileName.endsWith('.svg') && /^CD[56][A-Z]_/.test(fileName))
  .sort();

if (files.length === 0) {
  console.error('No CD5*.svg files found in', TARGET_DIR);
  process.exit(1);
}

function parseViewBox(svg) {
  const match = svg.match(/viewBox\s*=\s*"([^"]+)"/i);
  if (!match) {
    throw new Error('Missing viewBox');
  }

  const values = match[1].trim().split(/\s+/).map(Number);
  if (values.length !== 4 || values.some(Number.isNaN)) {
    throw new Error(`Invalid viewBox: ${match[1]}`);
  }

  const [, , width, height] = values;
  return { width, height, area: width * height };
}

function parseMetaBoxes(svg) {
  const boxes = [];
  const regex = /<g\s+[^>]*data-role="([^"]+)"[^>]*data-tier="([^"]+)"[^>]*data-bbox="([^"]+)"[^>]*\/>/g;
  let match;

  while ((match = regex.exec(svg)) !== null) {
    const role = match[1];
    const tier = match[2];
    const bbox = match[3].trim().split(/\s+/).map(Number);
    if (bbox.length !== 4 || bbox.some(Number.isNaN)) {
      throw new Error(`Invalid data-bbox for role ${role}: ${match[3]}`);
    }
    const [x, y, width, height] = bbox;
    boxes.push({ role, tier, x, y, width, height, area: width * height });
  }

  return boxes;
}

function formatPercent(value) {
  return `${(value * 100).toFixed(1)}%`;
}

function formatPx(value) {
  return `${value.toFixed(1)}px`;
}

function fitScore(actual, target, tolerance) {
  const delta = Math.abs(actual - target);
  return Math.max(0, 1 - (delta / tolerance));
}

function summarize(fileName, viewBox, boxes) {
  const primaryBoxes = boxes.filter((box) => box.tier === 'primary');
  const secondaryBoxes = boxes.filter((box) => box.tier === 'secondary');
  const supportBoxes = boxes.filter((box) => box.tier === 'support');

  const boxMetrics = boxes.map((box) => {
    const areaRatio = box.area / viewBox.area;
    const minSideAt64 = Math.min(box.width, box.height) * 64 / viewBox.width;
    const maxSideAt64 = Math.max(box.width, box.height) * 64 / viewBox.width;
    return {
      ...box,
      areaRatio,
      minSideAt64,
      maxSideAt64,
    };
  });

  const primaryCoverage = primaryBoxes.reduce((sum, box) => sum + box.area, 0) / viewBox.area;
  const secondaryCoverage = secondaryBoxes.reduce((sum, box) => sum + box.area, 0) / viewBox.area;
  const supportCoverage = supportBoxes.reduce((sum, box) => sum + box.area, 0) / viewBox.area;
  const largestPrimary = boxMetrics
    .filter((box) => box.tier === 'primary')
    .sort((a, b) => b.area - a.area)[0];

  const anchorStrength = largestPrimary
    ? (largestPrimary.areaRatio * 0.65) + ((largestPrimary.minSideAt64 / 64) * 0.35)
    : 0;

  const readabilityScore = (
    fitScore(primaryCoverage, 0.30, 0.16) * 0.28 +
    fitScore(secondaryCoverage, 0.23, 0.10) * 0.18 +
    fitScore(supportCoverage, 0.035, 0.025) * 0.10 +
    fitScore(largestPrimary?.areaRatio ?? 0, 0.16, 0.08) * 0.20 +
    fitScore(largestPrimary?.minSideAt64 ?? 0, 24, 12) * 0.24
  );

  return {
    fileName,
    boxMetrics,
    primaryCoverage,
    secondaryCoverage,
    supportCoverage,
    largestPrimary,
    anchorStrength,
    readabilityScore,
  };
}

function printSummary(summary) {
  console.log(`\n${summary.fileName}`);
  console.log(`  primary coverage : ${formatPercent(summary.primaryCoverage)}`);
  console.log(`  secondary cover. : ${formatPercent(summary.secondaryCoverage)}`);
  console.log(`  support coverage : ${formatPercent(summary.supportCoverage)}`);
  console.log(`  anchor strength  : ${summary.anchorStrength.toFixed(3)}`);
  console.log(`  readability score: ${summary.readabilityScore.toFixed(3)}`);
  if (summary.largestPrimary) {
    console.log(
      `  largest primary : ${summary.largestPrimary.role} ` +
      `(${formatPercent(summary.largestPrimary.areaRatio)}, ` +
      `min@64 ${formatPx(summary.largestPrimary.minSideAt64)}, ` +
      `max@64 ${formatPx(summary.largestPrimary.maxSideAt64)})`
    );
  }
  console.log('  role breakdown   :');
  for (const box of summary.boxMetrics) {
    console.log(
      `    - ${box.role.padEnd(16)} ${box.tier.padEnd(9)} ` +
      `${formatPercent(box.areaRatio).padStart(6)} ` +
      `min@64 ${formatPx(box.minSideAt64).padStart(6)} ` +
      `max@64 ${formatPx(box.maxSideAt64).padStart(6)}`
    );
  }
}

const summaries = files.map((fileName) => {
  const svg = fs.readFileSync(path.join(TARGET_DIR, fileName), 'utf8');
  const viewBox = parseViewBox(svg);
  const boxes = parseMetaBoxes(svg);
  if (boxes.length === 0) {
    throw new Error(`No visibility metadata found in ${fileName}`);
  }
  return summarize(fileName, viewBox, boxes);
});

for (const summary of summaries) {
  printSummary(summary);
}

console.log('\nRanking by readability score:');
[...summaries]
  .sort((a, b) => b.readabilityScore - a.readabilityScore)
  .forEach((summary, index) => {
    console.log(`  ${index + 1}. ${summary.fileName} (${summary.readabilityScore.toFixed(3)})`);
  });
