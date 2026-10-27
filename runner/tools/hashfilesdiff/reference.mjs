// The file selection of GitHub's hashFiles(): actions/runner's
// src/Misc/expressionFunc/hashFiles/src/hashFiles.ts, on the @actions/glob it pins (^0.7.0), with
// the same filters, reporting the files it would hash instead of hashing them. The runner passes the
// patterns joined by newlines and runs it in the workspace, without following symbolic links unless
// asked to.
//
//   node reference.mjs <cases.json> <workspace>    one JSON line per case: {"id", "files"}
import * as fs from 'fs'
import * as path from 'path'
import * as glob from '@actions/glob'

const [casesFile, workspace] = process.argv.slice(2)
const cases = JSON.parse(fs.readFileSync(casesFile, 'utf8'))
process.chdir(workspace)
const githubWorkspace = process.cwd()

for (const c of cases) {
  const files = []
  let error
  try {
    const globber = await glob.create(c.patterns.join('\n'), {followSymbolicLinks: false})
    for await (const file of globber.globGenerator()) {
      if (!file.startsWith(`${githubWorkspace}${path.sep}`)) continue
      if (fs.statSync(file).isDirectory()) continue
      files.push(path.relative(githubWorkspace, file))
    }
  } catch (e) {
    error = String(e.message || e)
  }
  files.sort()
  console.log(JSON.stringify(error === undefined ? {id: c.id, files} : {id: c.id, error}))
}
