import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const typesDirectory = dirname(dirname(fileURLToPath(import.meta.url)));
const templatePath = join(typesDirectory, 'buf.gen.yaml');
const args = process.argv.slice(2);

const getCommit = (providedArgs) => {
  if (providedArgs.length === 0) {
    return undefined;
  }

  if (providedArgs.length === 1 && !providedArgs[0].startsWith('--')) {
    return providedArgs[0];
  }

  if (providedArgs.length === 2 && providedArgs[0] === '--commit') {
    return providedArgs[1];
  }

  if (providedArgs.length === 1 && providedArgs[0].startsWith('--commit=')) {
    return providedArgs[0].slice('--commit='.length);
  }

  throw new Error('Usage: pnpm gen-types [commit] or pnpm gen-types --commit <commit>');
};

let temporaryDirectory;

try {
  const commit = getCommit(args);
  let bufArgs = ['generate'];

  if (commit !== undefined) {
    if (commit.length === 0 || /\s/.test(commit)) {
      throw new Error('The commit must not contain whitespace.');
    }

    const template = readFileSync(templatePath, 'utf8');
    const branchPattern = /^(\s*)branch: main$/gm;
    const branchMatches = template.match(branchPattern);

    if (branchMatches?.length !== 2) {
      throw new Error('Expected both protobuf inputs to use branch: main.');
    }

    const customTemplate = template.replace(
      branchPattern,
      (_, indentation) => `${indentation}ref: ${JSON.stringify(commit)}`,
    );

    temporaryDirectory = mkdtempSync(join(tmpdir(), 'osac-gen-types-'));
    const temporaryTemplatePath = join(temporaryDirectory, 'buf.gen.yaml');
    writeFileSync(temporaryTemplatePath, customTemplate);
    bufArgs = ['generate', '--template', temporaryTemplatePath];
  }

  const result = spawnSync('buf', bufArgs, {
    cwd: typesDirectory,
    stdio: 'inherit',
  });

  if (result.error) {
    throw result.error;
  }

  process.exitCode = result.status ?? 1;
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
} finally {
  if (temporaryDirectory) {
    rmSync(temporaryDirectory, { force: true, recursive: true });
  }
}
