// What GitHub's runner makes of a problem matcher's regular expression: actions/runner's
// IssueMatcher.cs builds each with `new Regex(pattern, RegexOptions.CultureInvariant |
// RegexOptions.ECMAScript, timeout)` and reads groups by number from `Match(line)`. This reports,
// for each case, whether .NET accepts the pattern and, for each input, whether it matches and the
// value of every group (null when the group took no part).
//
//   dotnet run -- <cases.json>    one JSON line per case: {"id", "error"} or {"id", "results"}
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;

var options = new JsonSerializerOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
var cases = JsonDocument.Parse(File.ReadAllText(args[0])).RootElement;
using var stdout = new StreamWriter(Console.OpenStandardOutput());
foreach (var c in cases.EnumerateArray())
{
    var id = c.GetProperty("id").GetInt32();
    Regex re;
    try
    {
        re = new Regex(c.GetProperty("pattern").GetString()!,
            RegexOptions.CultureInvariant | RegexOptions.ECMAScript, TimeSpan.FromSeconds(1));
    }
    catch (ArgumentException e)
    {
        stdout.WriteLine(JsonSerializer.Serialize(new { id, error = e.Message.Split('\n')[0] }, options));
        continue;
    }
    var numbers = re.GetGroupNumbers();
    var results = new List<object>();
    foreach (var input in c.GetProperty("inputs").EnumerateArray())
    {
        try
        {
            var m = re.Match(input.GetString()!);
            if (!m.Success) { results.Add(new { matched = false }); continue; }
            var groups = new Dictionary<string, string?>();
            foreach (var n in numbers)
                groups[n.ToString()] = m.Groups[n].Success ? m.Groups[n].Value : null;
            results.Add(new { matched = true, groups });
        }
        catch (RegexMatchTimeoutException)
        {
            results.Add(new { timeout = true });
        }
    }
    try { stdout.WriteLine(JsonSerializer.Serialize(new { id, results }, options)); }
    catch (Exception e) { stdout.WriteLine(JsonSerializer.Serialize(new { id, unreportable = e.Message }, options)); }
}
