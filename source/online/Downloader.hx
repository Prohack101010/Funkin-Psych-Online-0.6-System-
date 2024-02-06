package online;

import online.states.RequestState;
import sys.io.File;
import sys.thread.Thread;
import sys.io.FileOutput;
import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket;
import online.GameBanana.GBMod;
import sys.FileSystem;
// import haxe.Int64; note to self use float instead of int64

using StringTools;

class Downloader {
	var socket:Socket;
	var file:FileOutput;
	var id:String;
	var fileName:String;
	var gbMod:GBMod;

	var downloadPath:String;
	static var downloadDir:String = openfl.filesystem.File.applicationDirectory.nativePath + "/downloads/";

	var alert:DownloadAlert;

	static var downloading:Array<String> = [];
	public static var downloaders:Array<Downloader> = [];

	var onFinished:(String, Downloader)->Void;
	public var cancelRequested(default, null):Bool = false;
	var isDownloading:Bool = false;

	public var contentLength:Float = Math.POSITIVE_INFINITY;
	public var gotContent:Float = 0;
	
	public function new(fileName:String, id:String, url:String, onFinished:(fileName:String, downloader:Downloader) -> Void, ?mod:GBMod, ?headers:Map<String, String>) {
		this.fileName = idFilter(fileName);
		id = idFilter(id);
		if (downloading.contains(id)) {
			// Waiter.put(() -> {
			// 	Alert.alert('Downloading failed!', 'Download ' + id + " is already being downloaded!");
			// });
			return;
		}
		if (downloading.length >= 6) {
			Waiter.put(() -> {
				Alert.alert('Downloading failed!', 'Too many files are downloading right now! (Max 6)');
			});
			return;
		}
		this.onFinished = onFinished;
		this.gbMod = mod;
		if (ChatBox.instance != null && gbMod != null) {
			ChatBox.instance.addMessage("Starting the download of " + gbMod.name + " from: " + url);
		}
		this.id = id;
		downloaders.push(this);
		downloading.push(id);
		alert = new DownloadAlert(id);
		checkCreateDlDir();
		downloadPath = downloadDir + id + ".dwl";

		Thread.create(() -> {
			try {
				startDownload(url, headers);
			}
			catch (exc) {
				if (!cancelRequested) {
					Waiter.put(() -> {
						Alert.alert('Downloading failed!', id + ': ' + exc);
					});
				}
				doCancel();
			}
		});
	}

	static var allowedMediaTypes:Array<String> = [
		"application/zip",
		"application/zip-compressed",
		"application/x-zip-compressed",
		"application/x-zip",
		"application/x-tar",
		"application/gzip",
		"application/x-gtar",
	];

	public static function isMediaTypeAllowed(file:String) {
		file = file.trim();
		for (item in allowedMediaTypes) {
			if (file == item)
				return true;
		}
		return false;
	}

	private function startDownload(url:String, ?requestHeaders:Map<String, String>) {
		isDownloading = true;

		var urlFormat = getURLFormat(url);
		try {
			socket = !urlFormat.isSSL ? new Socket() : new sys.ssl.Socket();
			socket.connect(new Host(urlFormat.domain), urlFormat.port);
		}
		catch (exc) {
			if (!cancelRequested) {
				Waiter.put(() -> {
					Alert.alert('Downloading failed!', id + ': ' + exc);
				});
			}
			doCancel();
			return;
		}
		socket.setTimeout(10);

		if (cancelRequested) {
			doCancel();
			return;
		}

		var headers:String = "";
		headers += '\nHost: ${urlFormat.domain}:${urlFormat.port}';
		headers += '\nUser-Agent: haxe';
		if (requestHeaders != null) {
			for (key => value in requestHeaders) {
				headers += '\n$key: $value';
			}
		}

		socket.write('GET ${urlFormat.path} HTTP/1.1${headers}\n\n');

		var httpStatus:String = null;
		try {
			httpStatus = socket.input.readLine();
			httpStatus = httpStatus.substr(httpStatus.indexOf(" ")).ltrim();
		}
		catch (exc) {
			if (!cancelRequested) {
				Waiter.put(() -> {
					Alert.alert('Downloading failed, try again!', exc.toString());
				});
			}
			doCancel();
			return;
		}
		if (cancelRequested) {
			doCancel();
			return;
		}
		if (httpStatus.startsWith("4") || httpStatus.startsWith("5")) {
			if (!cancelRequested) {
				Waiter.put(() -> {
					Alert.alert('Downloading failed!', httpStatus);
				});
			}
			doCancel();
			return;
		}

		var gotHeaders:Map<String, String> = new Map<String, String>();
		while (gotContent < contentLength && !cancelRequested) {
			var readLine:String = socket.input.readLine();
			gotContent += readLine.length;
			if (readLine.trim() == "") {
				break;
			}
			var splitHeader = readLine.split(": ");
			if (splitHeader[0] == "Content-Length") {
				contentLength = Std.parseFloat(splitHeader[1]);
				// contentLength = Int64.parseString(splitHeader[1]);
			}
			gotHeaders.set(splitHeader[0], splitHeader[1]);
		}

		if (cancelRequested) {
			doCancel();
			return;
		}

		if (gotHeaders.exists("Location")) {
			Sys.println('Redirecting from $url to ${gotHeaders.get("Location")}');
			startDownload(gotHeaders.get("Location"), requestHeaders);
			return;
		}

		if (!gotHeaders.exists("Content-Length")) {
			if (!cancelRequested) {
				Waiter.put(() -> {
					Alert.alert('Downloading failed!', "Host didn't specified the byte length");
				});
			}
			doCancel();
			return;
		}

		if (!isMediaTypeAllowed(gotHeaders.get("Content-Type"))) {
			if (!cancelRequested) {
				Waiter.put(() -> {
					Alert.alert('Downloading failed!', gotHeaders.get("Content-Type") + " may be invalid or unsupported file type!");
					RequestState.requestURL(url, "The following mod needs to be installed from this source", true);
				});
			}
			doCancel();
			return;
		}

		try {
			file = File.append(downloadPath, true);
		}
		catch (exc) {
			file = null;
			if (!cancelRequested) {
				Waiter.put(() -> {
					Alert.alert('Downloading failed!', exc.toString());
				});
			}
			doCancel();
			return;
		}
		
		var buffer:Bytes = Bytes.alloc(1024);
		var _bytesWritten:Int = 0;
		while (gotContent < contentLength && !cancelRequested) {
			_bytesWritten = socket.input.readBytes(buffer, 0, buffer.length);
			file.writeBytes(buffer, 0, _bytesWritten);
			gotContent += _bytesWritten;
		}
		isDownloading = false;

		doCancel(!cancelRequested);
	}

	function getURLFormat(url:String):URLFormat {
		var urlFormat:URLFormat = {
			isSSL: false,
			domain: "",
			port: 80,
			path: ""
		};

		if (url.startsWith("https://")) {
			urlFormat.isSSL = true;
			urlFormat.port = 443;
			url = url.substr("https://".length);
		}
		else if (url.startsWith("http://")) {
			urlFormat.isSSL = false;
			urlFormat.port = 80;
			url = url.substr("http://".length);
		}

		urlFormat.domain = url.substring(0, url.indexOf("/"));
		if (urlFormat.domain.indexOf(":") != -1) {
			var split = urlFormat.domain.split(":");
			urlFormat.domain = split[0];
			urlFormat.port = Std.parseInt(split[1]);
		}
		urlFormat.path = url.substr(url.indexOf("/"));

		return urlFormat;
	}

	public static function checkCreateDlDir() {
		if (!FileSystem.exists(downloadDir)) {
			FileSystem.createDirectory(downloadDir);
		}
	}

	public static function checkDeleteDlDir() {
		if (FileSystem.exists(downloadDir)) {
			FileUtils.removeFiles(downloadDir);
		}
	}

	public function tryRenameFile():String {
		if (FileSystem.exists(downloadPath)) {
			if (FileSystem.exists(downloadDir + fileName))
				FileSystem.deleteFile(downloadDir + fileName);
			FileSystem.rename(downloadPath, downloadDir + fileName);
		}
		return downloadDir + fileName;
	}

	function deleteTempFile() {
		if (FileSystem.exists(downloadPath)) {
			FileSystem.deleteFile(downloadPath);
		}
	}

	public function cancel() {
		if (isDownloading) {
			cancelRequested = true;
			return;
		}

		doCancel();
	}

	function doCancel(?callOnFinished:Bool = false) {
		Sys.println('Download $id cancelled!');
		if (socket != null)
			socket.close();
		socket = null;
		if (file != null)
			file.close();
		if (callOnFinished) {
			onFinished(downloadPath, this);
		}
		downloading.remove(id);
		downloaders.remove(this);
		if (alert != null)
			alert.destroy();
		alert = null;
		try {
			deleteTempFile();
		}
		catch (exc) {
		}
	}

	public static function cancelAll() {
		Sys.println("Cancelling " + downloaders.length + " downloads...");
		for (downloader in downloaders) {
			if (downloader != null)
				downloader.cancel();
		}
	}

	static function isNumber(char:Int) {
		return char >= 48 && char <= 57; // 0-9
	}

	static function isLetter(char:Int) {
		return (char >= 65 && char <= 90) || /* A-Z */ (char >= 97 && char <= 122); // a-z
	}
	
	public static function idFilter(id:String):String {
		var filtered = "";
		var i = -1;
		while (++i < id.length) {
			var char = id.charCodeAt(i);
			if (isNumber(char) || isLetter(char))
				filtered += id.charAt(i);
			else
				filtered += "-";
		}
		return filtered;
	}
}

typedef URLFormat = {
	var isSSL:Bool;
	var domain:String;
	var port:Int;
	var path:String;
}