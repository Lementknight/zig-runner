// GitHub's hashFiles(): actions/runner's HashFilesFunction.cs (the arguments: a first one starting
// with `--` is an option, the rest joined by newlines) and its hashFiles.ts script on the
// @actions/glob it pins (^0.7.0), run in the workspace. Reports the files it hashes, in order, and
// the hash.
//
//   node reference.mjs <cases.json> <workspace>    one JSON line per case: {"id", "files", "hash"}
//                                                  or {"id", "error"}
import * as crypto from 'crypto'
import * as fs from 'fs'
import * as path from 'path'
import * as glob from '@actions/glob'

const [casesFile, workspace] = process.argv.slice(2)
const cases = JSON.parse(fs.readFileSync(casesFile, 'utf8'))
process.chdir(workspace)
const githubWorkspace = process.cwd()

for (const c of cases) {
  try {
    let args = c.patterns
    let followSymbolicLinks = false
    if (args.length > 0 && args[0].startsWith('--')) {
      if (args[0].toLowerCase() !== '--follow-symbolic-links') throw new Error(`Invalid glob option ${args[0]}`)
      followSymbolicLinks = true
      args = args.slice(1)
    }
    const result = crypto.createHash('sha256')
    const files = []
    const globber = await glob.create(args.join('\n'), {followSymbolicLinks})
    for await (const file of globber.globGenerator()) {
      if (!file.startsWith(`${githubWorkspace}${path.sep}`)) continue
      if (fs.statSync(file).isDirectory()) continue
      result.write(crypto.createHash('sha256').update(fs.readFileSync(file)).digest())
      files.push(path.relative(githubWorkspace, file))
    }
    result.end()
    console.log(JSON.stringify({id: c.id, files, hash: files.length > 0 ? result.digest('hex') : ''}))
  } catch (e) {
    console.log(JSON.stringify({id: c.id, error: String(e.message || e).split('\n')[0]}))
  }
}
