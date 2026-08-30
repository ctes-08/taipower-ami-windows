using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

internal static class NativeHostLauncher
{
    private const int HeaderBytes = 4;
    private const int MaxRequestBytes = 64 * 1024;
    private const int MaxResponseBytes = 64 * 1024;
    private const int MaxTaipowerResponseBytes = 2 * 1024 * 1024;
    private const int MaxCredentialTemporaryBytes = 64 * 1024;
    private const int MaxCredentialTemporaryCandidates = 256;
    private const int InputTimeoutMilliseconds = 3000;
    private const int NetworkTimeoutMilliseconds = 25000;
    private const int TotalTimeoutMilliseconds = 45000;
    private const int StaleCredentialTemporaryMinimumAgeMinutes = 5;
    private const string CredentialTemporaryPrefix = ".credentials.json.";
    private const string CredentialTemporarySuffix = ".tmp";
    private const string ExpectedOrigin =
        "chrome-extension://ajnbiemabobkigpbnfmoekolceigkica/";
    private const string ConfigurationSubKey = @"Software\TaipowerAMI";
    private const string CredentialDestinationValue = "CredentialDestination";
    private const string ApiRoot =
        "https://service.taipower.com.tw/ebpps2/amichart/api/yearlist";

    private const int MoveFileReplaceExisting = 0x1;
    private const int MoveFileWriteThrough = 0x8;
    private const uint NativeFileShareRead = 0x1;
    private const uint NativeFileShareWrite = 0x2;
    private const uint NativeFileShareDelete = 0x4;
    private const uint NativeOpenExisting = 3;
    private const uint NativeFileFlagBackupSemantics = 0x02000000;

    private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);

    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer
    {
        MaxJsonLength = MaxTaipowerResponseBytes,
        RecursionLimit = 32
    };

    private static int responseClaimed;

    private sealed class SafeHostException : Exception
    {
        internal SafeHostException(string message, int exitCode)
            : base(message)
        {
            ExitCode = exitCode;
        }

        internal int ExitCode { get; private set; }
    }

    private sealed class HandoffMaterial
    {
        internal string Session;
        internal string Enkey;
        internal DateTime CapturedDay;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool MoveFileEx(
        string existingFileName,
        string newFileName,
        int flags
    );

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile
    );

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(
        IntPtr file,
        StringBuilder filePath,
        uint filePathLength,
        uint flags
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    private static Dictionary<string, object> ErrorResponse(string message)
    {
        return new Dictionary<string, object>
        {
            { "status", "error" },
            { "error", message },
            { "secrets_printed", false }
        };
    }

    private static bool TryWriteResponse(Dictionary<string, object> response)
    {
        byte[] payload;
        try
        {
            payload = new UTF8Encoding(false, true).GetBytes(Json.Serialize(response));
        }
        catch (Exception)
        {
            payload = Encoding.UTF8.GetBytes(
                "{\"status\":\"error\",\"error\":\"本機交接回應建立失敗\","
                + "\"secrets_printed\":false}"
            );
        }
        if (payload.Length == 0 || payload.Length > MaxResponseBytes)
        {
            return false;
        }
        if (Interlocked.CompareExchange(ref responseClaimed, 1, 0) != 0)
        {
            return false;
        }
        try
        {
            var output = Console.OpenStandardOutput();
            var header = BitConverter.GetBytes(payload.Length);
            output.Write(header, 0, header.Length);
            output.Write(payload, 0, payload.Length);
            output.Flush();
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool ReadExactly(Stream input, byte[] buffer, int offset, int count)
    {
        while (count > 0)
        {
            var read = input.Read(buffer, offset, count);
            if (read == 0)
            {
                return false;
            }
            offset += read;
            count -= read;
        }
        return true;
    }

    private static byte[] ReadSinglePayload(Stream input)
    {
        var header = new byte[HeaderBytes];
        if (!ReadExactly(input, header, 0, header.Length))
        {
            throw new SafeHostException("本機交接訊息不完整", 72);
        }
        var length = BitConverter.ToUInt32(header, 0);
        if (length == 0 || length > MaxRequestBytes)
        {
            throw new SafeHostException("本機交接訊息大小不符", 72);
        }
        var payload = new byte[(int)length];
        if (!ReadExactly(input, payload, 0, payload.Length))
        {
            throw new SafeHostException("本機交接訊息不完整", 72);
        }
        return payload;
    }

    private static byte[] ReadSinglePayloadWithTimeout()
    {
        byte[] payload = null;
        Exception failure = null;
        var completed = new ManualResetEvent(false);
        var reader = new Thread(() =>
        {
            try
            {
                payload = ReadSinglePayload(Console.OpenStandardInput());
            }
            catch (Exception exception)
            {
                failure = exception;
            }
            finally
            {
                try { completed.Set(); }
                catch (ObjectDisposedException) { }
            }
        });
        reader.IsBackground = true;
        reader.Start();
        if (!completed.WaitOne(InputTimeoutMilliseconds))
        {
            completed.Dispose();
            throw new SafeHostException("本機交接訊息讀取逾時", 72);
        }
        completed.Dispose();
        if (failure is SafeHostException)
        {
            throw (SafeHostException)failure;
        }
        if (failure != null || payload == null)
        {
            throw new SafeHostException("本機交接訊息讀取失敗", 72);
        }
        return payload;
    }

    private static HandoffMaterial ParseRequest(byte[] payload)
    {
        string text;
        try
        {
            text = new UTF8Encoding(false, true).GetString(payload);
        }
        catch (DecoderFallbackException)
        {
            throw new SafeHostException("本機交接訊息不是有效 UTF-8", 1);
        }

        Dictionary<string, object> root;
        try
        {
            root = Json.DeserializeObject(text) as Dictionary<string, object>;
        }
        catch (Exception)
        {
            throw new SafeHostException("本機交接訊息不是有效 JSON", 1);
        }
        if (root == null || root.Count != 5)
        {
            throw new SafeHostException("本機交接訊息欄位不符", 1);
        }
        var required = new[] { "version", "action", "session", "enkey", "captured_day" };
        foreach (var field in required)
        {
            if (!root.ContainsKey(field))
            {
                throw new SafeHostException("本機交接訊息欄位不符", 1);
            }
        }
        if (!(root["version"] is int) || (int)root["version"] != 1)
        {
            throw new SafeHostException("本機交接訊息版本不支援", 1);
        }
        if (!string.Equals(root["action"] as string, "import", StringComparison.Ordinal))
        {
            throw new SafeHostException("本機交接動作不支援", 1);
        }

        var session = ValidateSession(root["session"]);
        var enkey = ValidateEnkey(root["enkey"]);
        var capturedDayText = root["captured_day"] as string;
        DateTime capturedDay;
        if (capturedDayText == null || !DateTime.TryParseExact(
            capturedDayText,
            "yyyy-MM-dd",
            CultureInfo.InvariantCulture,
            DateTimeStyles.None,
            out capturedDay
        ))
        {
            throw new SafeHostException("擷取日期格式不符", 1);
        }
        var today = TaipeiNow().Date;
        if (Math.Abs((today - capturedDay.Date).TotalDays) > 1)
        {
            throw new SafeHostException("擷取日期超出允許範圍", 1);
        }
        return new HandoffMaterial
        {
            Session = session,
            Enkey = enkey,
            CapturedDay = capturedDay.Date
        };
    }

    private static string ValidateOpaque(string name, object value)
    {
        var text = value as string;
        if (text == null || text.Length < 8 || text.Length > 512)
        {
            throw new SafeHostException(name + " 格式不符", 1);
        }
        foreach (var character in text)
        {
            if (character < 0x20 || char.IsWhiteSpace(character))
            {
                throw new SafeHostException(name + " 格式不符", 1);
            }
        }
        return text;
    }

    private static string ValidateSession(object value)
    {
        var session = ValidateOpaque("SESSION", value);
        foreach (var character in session)
        {
            var code = (int)character;
            var allowed = code == 0x21
                || (code >= 0x23 && code <= 0x2B)
                || (code >= 0x2D && code <= 0x3A)
                || (code >= 0x3C && code <= 0x5B)
                || (code >= 0x5D && code <= 0x7E);
            if (!allowed)
            {
                throw new SafeHostException("SESSION 格式不符", 1);
            }
        }
        return session;
    }

    private static string ValidateEnkey(object value)
    {
        var enkey = ValidateOpaque("AMI 識別碼", value);
        if (enkey.IndexOf('/') >= 0 || enkey.IndexOf('\\') >= 0)
        {
            throw new SafeHostException("AMI 識別碼格式不符", 1);
        }
        return enkey;
    }

    private static DateTime TaipeiNow()
    {
        try
        {
            var zone = TimeZoneInfo.FindSystemTimeZoneById("Taipei Standard Time");
            return TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, zone);
        }
        catch (TimeZoneNotFoundException)
        {
            return DateTime.Now;
        }
        catch (InvalidTimeZoneException)
        {
            return DateTime.Now;
        }
    }

    private static int ValidateWithTaipower(HandoffMaterial material)
    {
        // This executable targets .NET Framework v4.  Do not rely on machine-wide
        // SchUseStrongCrypto/SystemDefaultTlsVersions registry settings: systems
        // without those values otherwise negotiate obsolete TLS 1.0 first.
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;

        var rocYear = TaipeiNow().Year - 1911;
        var url = ApiRoot
            + "?enkey=" + Uri.EscapeDataString(material.Enkey)
            + "&year=" + rocYear.ToString("000", CultureInfo.InvariantCulture);
        var request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = "GET";
        request.Accept = "application/json";
        request.Headers[HttpRequestHeader.Cookie] = "SESSION=" + material.Session;
        request.AllowAutoRedirect = false;
        request.Proxy = null;
        request.KeepAlive = false;
        request.Timeout = NetworkTimeoutMilliseconds;
        request.ReadWriteTimeout = NetworkTimeoutMilliseconds;
        request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;

        HttpWebResponse response;
        try
        {
            response = (HttpWebResponse)request.GetResponse();
        }
        catch (WebException exception)
        {
            var errorResponse = exception.Response as HttpWebResponse;
            if (errorResponse != null)
            {
                using (errorResponse)
                {
                    var status = (int)errorResponse.StatusCode;
                    if (status == 301 || status == 302 || status == 303
                        || status == 307 || status == 308 || status == 401 || status == 403)
                    {
                        throw new SafeHostException("台電 SESSION 已失效或未獲授權", 2);
                    }
                    if (status == 429)
                    {
                        throw new SafeHostException("台電暫時限制請求，請稍後再試", 1);
                    }
                    throw new SafeHostException("台電服務回傳 HTTP " + status, 1);
                }
            }
            if (exception.Status == WebExceptionStatus.Timeout)
            {
                throw new SafeHostException("台電唯讀驗證逾時", 1);
            }
            if (exception.Status == WebExceptionStatus.SecureChannelFailure)
            {
                throw new SafeHostException("無法與台電協商安全的 TLS 連線", 1);
            }
            if (exception.Status == WebExceptionStatus.TrustFailure)
            {
                throw new SafeHostException("台電 TLS 憑證驗證失敗", 1);
            }
            if (exception.Status == WebExceptionStatus.NameResolutionFailure)
            {
                throw new SafeHostException("Windows DNS 無法解析台電網域", 1);
            }
            if (exception.Status == WebExceptionStatus.ConnectFailure)
            {
                throw new SafeHostException("無法建立台電 TCP 連線", 1);
            }
            if (exception.Status == WebExceptionStatus.ReceiveFailure
                || exception.Status == WebExceptionStatus.ConnectionClosed)
            {
                throw new SafeHostException("台電連線在回應前中斷", 1);
            }
            throw new SafeHostException("目前無法連線到台電唯讀端點", 1);
        }

        using (response)
        {
            var status = (int)response.StatusCode;
            if (status >= 300 && status <= 399)
            {
                throw new SafeHostException("台電 SESSION 已失效或未獲授權", 2);
            }
            if (status != 200)
            {
                throw new SafeHostException("台電服務回傳 HTTP " + status, 1);
            }
            var contentType = response.ContentType ?? "";
            var separator = contentType.IndexOf(';');
            if (separator >= 0)
            {
                contentType = contentType.Substring(0, separator);
            }
            if (!string.Equals(
                contentType.Trim(),
                "application/json",
                StringComparison.OrdinalIgnoreCase
            ))
            {
                throw new SafeHostException("台電 SESSION 已失效或未獲授權", 2);
            }
            var raw = ReadLimited(response.GetResponseStream(), MaxTaipowerResponseBytes);
            string jsonText;
            try
            {
                jsonText = new UTF8Encoding(false, true).GetString(raw);
                if (jsonText.Length > 0 && jsonText[0] == '\uFEFF')
                {
                    jsonText = jsonText.Substring(1);
                }
            }
            catch (DecoderFallbackException)
            {
                throw new SafeHostException("台電回應不是有效 UTF-8 JSON", 1);
            }
            Dictionary<string, object> root;
            try
            {
                root = Json.DeserializeObject(jsonText) as Dictionary<string, object>;
            }
            catch (Exception)
            {
                throw new SafeHostException("台電回應不是有效 JSON", 1);
            }
            if (root == null)
            {
                throw new SafeHostException("台電回應格式不符", 1);
            }
            object code;
            if (!root.TryGetValue("msgCode", out code)
                || !string.Equals(code as string, "AMI0000", StringComparison.Ordinal))
            {
                throw new SafeHostException("台電 API 未接受這次授權", 2);
            }
            object rowsValue;
            if (!root.TryGetValue("listAMIBase4PeriodData", out rowsValue))
            {
                throw new SafeHostException("台電年用電回應缺少資料列", 1);
            }
            var rows = rowsValue as IList;
            if (rows == null)
            {
                throw new SafeHostException("台電年用電資料格式不符", 1);
            }
            foreach (var row in rows)
            {
                if (!(row is Dictionary<string, object>))
                {
                    throw new SafeHostException("台電年用電資料格式不符", 1);
                }
            }
            return rows.Count;
        }
    }

    private static byte[] ReadLimited(Stream input, int maximumBytes)
    {
        if (input == null)
        {
            throw new SafeHostException("台電回應沒有內容", 1);
        }
        using (input)
        using (var buffer = new MemoryStream())
        {
            var chunk = new byte[8192];
            while (true)
            {
                var read = input.Read(chunk, 0, chunk.Length);
                if (read == 0)
                {
                    break;
                }
                if (buffer.Length + read > maximumBytes)
                {
                    throw new SafeHostException("台電回應超過安全大小限制", 1);
                }
                buffer.Write(chunk, 0, read);
            }
            return buffer.ToArray();
        }
    }

    private static string GetCredentialDestination()
    {
        string configured;
        try
        {
            using (var currentUser = RegistryKey.OpenBaseKey(
                RegistryHive.CurrentUser,
                RegistryView.Registry64
            ))
            using (var key = currentUser.OpenSubKey(ConfigurationSubKey, false))
            {
                if (key == null
                    || Array.IndexOf(key.GetValueNames(), CredentialDestinationValue) < 0
                    || key.GetValueKind(CredentialDestinationValue) != RegistryValueKind.String)
                {
                    throw new SafeHostException("HA 憑證目的地尚未設定", 1);
                }
                configured = key.GetValue(
                    CredentialDestinationValue,
                    null,
                    RegistryValueOptions.DoNotExpandEnvironmentNames
                ) as string;
            }
        }
        catch (SafeHostException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new SafeHostException("無法讀取 HA 憑證目的地設定", 1);
        }

        if (string.IsNullOrWhiteSpace(configured)
            || configured.IndexOf('\0') >= 0
            || configured.IndexOf('%') >= 0
            || configured.StartsWith(@"\\?\", StringComparison.Ordinal)
            || configured.StartsWith(@"\\.\", StringComparison.Ordinal)
            || configured.StartsWith(@"\??\", StringComparison.Ordinal))
        {
            throw new SafeHostException("HA 憑證目的地設定無效", 1);
        }

        var driveQualified = configured.Length >= 3
            && char.IsLetter(configured[0])
            && configured[1] == ':'
            && (configured[2] == '\\' || configured[2] == '/');
        var uncQualified = configured.StartsWith(@"\\", StringComparison.Ordinal)
            && configured.Length > 2;
        if (!driveQualified && !uncQualified)
        {
            throw new SafeHostException("HA 憑證目的地必須是完整路徑", 1);
        }

        string destination;
        try
        {
            destination = Path.GetFullPath(configured);
        }
        catch (Exception)
        {
            throw new SafeHostException("HA 憑證目的地設定無效", 1);
        }

        var root = Path.GetPathRoot(destination);
        if (string.IsNullOrEmpty(root)
            || !string.Equals(
                Path.GetFileName(destination),
                "credentials.json",
                StringComparison.OrdinalIgnoreCase
            )
            || destination.Substring(root.Length).IndexOf(':') >= 0)
        {
            throw new SafeHostException("HA 憑證目的地設定無效", 1);
        }
        if (driveQualified)
        {
            try
            {
                if (new DriveInfo(root).DriveType == DriveType.Network)
                {
                    throw new SafeHostException("HA 網路憑證目的地必須使用 UNC 路徑", 1);
                }
            }
            catch (SafeHostException)
            {
                throw;
            }
            catch (Exception)
            {
                throw new SafeHostException("HA 憑證目的地磁碟無法驗證", 1);
            }
        }
        foreach (var segment in destination.Substring(root.Length).Split(
            new[] { '\\', '/' },
            StringSplitOptions.RemoveEmptyEntries
        ))
        {
            if (segment.EndsWith(".", StringComparison.Ordinal)
                || segment.EndsWith(" ", StringComparison.Ordinal))
            {
                throw new SafeHostException("HA 憑證目的地設定無效", 1);
            }
        }

        if (uncQualified)
        {
            var uncParts = destination.Substring(2).Split(
                new[] { '\\', '/' },
                StringSplitOptions.RemoveEmptyEntries
            );
            if (uncParts.Length < 3)
            {
                throw new SafeHostException("HA 憑證 UNC 目的地設定無效", 1);
            }
        }
        return destination;
    }

    private static string NormalizeFinalDirectoryPath(string path)
    {
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
        {
            path = @"\\" + path.Substring(8);
        }
        else if (path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
        {
            path = path.Substring(4);
        }
        var fullPath = Path.GetFullPath(path);
        var root = Path.GetPathRoot(fullPath);
        if (!string.IsNullOrEmpty(root)
            && string.Equals(
                fullPath.TrimEnd('\\', '/'),
                root.TrimEnd('\\', '/'),
                StringComparison.OrdinalIgnoreCase
            ))
        {
            return root;
        }
        return fullPath.TrimEnd('\\', '/');
    }

    private static string GetFinalDirectoryPath(string directory)
    {
        var handle = CreateFile(
            directory,
            0,
            NativeFileShareRead | NativeFileShareWrite | NativeFileShareDelete,
            IntPtr.Zero,
            NativeOpenExisting,
            NativeFileFlagBackupSemantics,
            IntPtr.Zero
        );
        if (handle == InvalidHandleValue)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try
        {
            var buffer = new StringBuilder(1024);
            var length = GetFinalPathNameByHandle(
                handle,
                buffer,
                (uint)buffer.Capacity,
                0
            );
            if (length == 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (length >= buffer.Capacity)
            {
                buffer = new StringBuilder(checked((int)length + 1));
                length = GetFinalPathNameByHandle(
                    handle,
                    buffer,
                    (uint)buffer.Capacity,
                    0
                );
                if (length == 0 || length >= buffer.Capacity)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            return NormalizeFinalDirectoryPath(buffer.ToString());
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    private static string ValidateCredentialDestinationDirectory(string destination)
    {
        var directory = Path.GetDirectoryName(destination);
        if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory))
        {
            throw new SafeHostException("HA 憑證路徑無效", 1);
        }
        try
        {
            for (var current = new DirectoryInfo(directory); current != null; current = current.Parent)
            {
                if ((File.GetAttributes(current.FullName) & FileAttributes.ReparsePoint) != 0)
                {
                    throw new SafeHostException("HA 憑證路徑不允許重新解析點", 1);
                }
            }
            if (File.Exists(destination)
                && (File.GetAttributes(destination) & FileAttributes.ReparsePoint) != 0)
            {
                throw new SafeHostException("HA 憑證檔不允許重新解析點", 1);
            }

            var expectedDirectory = NormalizeFinalDirectoryPath(directory);
            var observedDirectory = GetFinalDirectoryPath(directory);
            if (!string.Equals(
                expectedDirectory,
                observedDirectory,
                StringComparison.OrdinalIgnoreCase
            ))
            {
                throw new SafeHostException("HA 憑證路徑解析結果不一致", 1);
            }
            return expectedDirectory;
        }
        catch (SafeHostException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new SafeHostException("無法驗證 HA 憑證路徑", 1);
        }
    }

    private static string ConfirmCredentialDestination(string expected)
    {
        var observed = GetCredentialDestination();
        if (!string.Equals(observed, expected, StringComparison.OrdinalIgnoreCase))
        {
            throw new SafeHostException("HA 憑證目的地設定已變更", 1);
        }
        return ValidateCredentialDestinationDirectory(observed);
    }

    private static bool IsCredentialTemporaryFileName(string fileName)
    {
        if (fileName == null
            || fileName.Length != CredentialTemporaryPrefix.Length + 32 + CredentialTemporarySuffix.Length
            || !fileName.StartsWith(CredentialTemporaryPrefix, StringComparison.Ordinal)
            || !fileName.EndsWith(CredentialTemporarySuffix, StringComparison.Ordinal))
        {
            return false;
        }
        var hexadecimalStart = CredentialTemporaryPrefix.Length;
        for (var index = hexadecimalStart; index < hexadecimalStart + 32; index++)
        {
            var character = fileName[index];
            if (!((character >= '0' && character <= '9')
                || (character >= 'a' && character <= 'f')))
            {
                return false;
            }
        }
        return true;
    }

    private static int CleanupStaleCredentialTemporaryFiles(string directory)
    {
        var removed = 0;
        var inspected = 0;
        var staleBefore = DateTime.UtcNow.AddMinutes(-StaleCredentialTemporaryMinimumAgeMinutes);
        try
        {
            foreach (var candidate in Directory.EnumerateFileSystemEntries(
                directory,
                CredentialTemporaryPrefix + "*" + CredentialTemporarySuffix,
                SearchOption.TopDirectoryOnly
            ))
            {
                inspected++;
                if (inspected > MaxCredentialTemporaryCandidates)
                {
                    break;
                }
                try
                {
                    var fileName = Path.GetFileName(candidate);
                    if (!IsCredentialTemporaryFileName(fileName))
                    {
                        continue;
                    }
                    var attributes = File.GetAttributes(candidate);
                    if ((attributes & (FileAttributes.Directory
                        | FileAttributes.Device
                        | FileAttributes.ReparsePoint)) != 0)
                    {
                        continue;
                    }
                    var file = new FileInfo(candidate);
                    file.Refresh();
                    if (!file.Exists
                        || file.Length < 0
                        || file.Length > MaxCredentialTemporaryBytes
                        || file.LastWriteTimeUtc > staleBefore)
                    {
                        continue;
                    }
                    attributes = File.GetAttributes(candidate);
                    if ((attributes & (FileAttributes.Directory
                        | FileAttributes.Device
                        | FileAttributes.ReparsePoint)) != 0)
                    {
                        continue;
                    }
                    File.Delete(candidate);
                    removed++;
                }
                catch (Exception)
                {
                    // Cleanup is deliberately best effort. Unsafe, replaced,
                    // active, oversized, or inaccessible entries are retained.
                }
            }
        }
        catch (Exception)
        {
            // A cleanup scan must not expand the handoff trust boundary.
        }
        return removed;
    }

    private static string WriteCredentialsAtomic(HandoffMaterial material)
    {
        var destination = GetCredentialDestination();
        var importedAt = DateTimeOffset.Now.ToString(
            "yyyy-MM-dd'T'HH:mm:sszzz",
            CultureInfo.InvariantCulture
        );
        var document = new Dictionary<string, object>
        {
            { "version", 1 },
            { "session", material.Session },
            { "enkey", material.Enkey },
            { "imported_at", importedAt },
            { "captured_day", material.CapturedDay.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) },
            { "session_refreshed_at", null }
        };
        var encoded = new UTF8Encoding(false, true).GetBytes(Json.Serialize(document) + "\n");
        var directory = ConfirmCredentialDestination(destination);
        CleanupStaleCredentialTemporaryFiles(directory);
        directory = ConfirmCredentialDestination(destination);
        var temporary = Path.Combine(
            directory,
            ".credentials.json." + Guid.NewGuid().ToString("N") + ".tmp"
        );
        try
        {
            using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None
            ))
            {
                stream.Write(encoded, 0, encoded.Length);
                stream.Flush(true);
            }
            ConfirmCredentialDestination(destination);
            if (!MoveFileEx(
                temporary,
                destination,
                MoveFileReplaceExisting | MoveFileWriteThrough
            ))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            ConfirmCredentialDestination(destination);
            var checkText = File.ReadAllText(destination, new UTF8Encoding(false, true));
            var check = Json.DeserializeObject(checkText) as Dictionary<string, object>;
            if (check == null
                || !object.Equals(check["version"], 1)
                || !string.Equals(check["session"] as string, material.Session, StringComparison.Ordinal)
                || !string.Equals(check["enkey"] as string, material.Enkey, StringComparison.Ordinal)
                || !string.Equals(check["imported_at"] as string, importedAt, StringComparison.Ordinal))
            {
                throw new SafeHostException("HA 憑證檔寫入後驗證失敗", 1);
            }
            return importedAt;
        }
        catch (SafeHostException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new SafeHostException("無法安全寫入 HA 憑證檔", 1);
        }
        finally
        {
            try
            {
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
            catch (Exception) { }
        }
    }

    public static int Main(string[] args)
    {
        if (args.Length < 1 || !string.Equals(args[0], ExpectedOrigin, StringComparison.Ordinal))
        {
            TryWriteResponse(ErrorResponse("未授權的擴充功能來源"));
            return 3;
        }

        Timer watchdog = null;
        watchdog = new Timer(_ =>
        {
            if (TryWriteResponse(ErrorResponse("本機交接超過 45 秒，已強制終止")))
            {
                Environment.Exit(73);
            }
        }, null, TotalTimeoutMilliseconds, Timeout.Infinite);

        try
        {
            var payload = ReadSinglePayloadWithTimeout();
            var material = ParseRequest(payload);
            var validationRows = ValidateWithTaipower(material);
            var importedAt = WriteCredentialsAtomic(material);
            TryWriteResponse(new Dictionary<string, object>
            {
                { "status", "ok" },
                { "imported_at", importedAt },
                { "validation", "official_read_only_yearlist" },
                { "validation_rows", validationRows },
                { "secrets_printed", false }
            });
            return 0;
        }
        catch (SafeHostException exception)
        {
            TryWriteResponse(ErrorResponse(exception.Message));
            return exception.ExitCode;
        }
        catch (Exception exception)
        {
            TryWriteResponse(ErrorResponse(
                "本機交接發生非預期錯誤 (" + exception.GetType().Name + ")"
            ));
            return 1;
        }
        finally
        {
            if (watchdog != null)
            {
                watchdog.Dispose();
            }
        }
    }
}
