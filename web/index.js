// We make use of this 'server' variable to provide the address of the
// REST Janus API. By default, in this example we assume that Janus is
// co-located with the web server hosting the HTML pages but listening
// on a different port (8088, the default for HTTP in Janus), which is
// why we make use of the 'window.location.hostname' base address. Since
// Janus can also do HTTPS, and considering we don't really want to make
// use of HTTP for Janus if your demos are served on HTTPS, we also rely
// on the 'window.location.protocol' prefix to build the variable, in
// particular to also change the port used to contact Janus (8088 for
// HTTP and 8089 for HTTPS, if enabled).
// In case you place Janus behind an Apache frontend (as we did on the
// online demos at http://janus.conf.meetecho.com) you can just use a
// relative path for the variable, e.g.:
//
// 		var server = "/janus";
//
// which will take care of this on its own.
//
//
// If you want to use the WebSockets frontend to Janus, instead, you'll
// have to pass a different kind of address, e.g.:
//
// 		var server = "ws://" + window.location.hostname + ":8188";
//
// Of course this assumes that support for WebSockets has been built in
// when compiling the server. WebSockets support has not been tested
// as much as the REST API, so handle with care!
//
//
// If you have multiple options available, and want to let the library
// autodetect the best way to contact your server (or pool of servers),
// you can also pass an array of servers, e.g., to provide alternative
// means of access (e.g., try WebSockets first and, if that fails, fall
// back to plain HTTP) or just have failover servers:
//
//		var server = [
//			"ws://" + window.location.hostname + ":8188",
//			"/janus"
//		];
//
// This will tell the library to try connecting to each of the servers
// in the presented order. The first working server will be used for
// the whole session.
//
var server = null;
if(window.location.protocol === 'http:')
	server = "http://" + window.location.hostname + ":8088/janus";
else
	server = "https://" + window.location.hostname + ":8089/janus";

var janus = null;
var streaming = null, controller = null;
var opaqueId = "webrtc-piano-"+Janus.randomString(12);

var myname = null, mycolor = createRandomColor();

var streamId = 2019;
var notes = {}, bgs = {};

$(document).ready(function() {
	// Initialize the library (all console debuggers enabled)
	Janus.init({debug: "all", callback: function() {
		// Use a button to start the demo
		$('#start').one('click', function() {
			$(this).attr('disabled', true).unbind('click');
			// Make sure the browser supports WebRTC
			if(!Janus.isWebrtcSupported()) {
				bootbox.alert("No WebRTC support... ");
				return;
			}
			// Create session
			janus = new Janus(
				{
					server: server,
					success: function() {
						// Prompt for a name
						askForName();
					},
					error: function(error) {
						Janus.error(error);
						bootbox.alert(error, function() {
							window.location.reload();
						});
					},
					destroyed: function() {
						window.location.reload();
					}
				});
		});
	}});
});

function askForName() {
	bootbox.prompt("What's your name?", function(result) { 
		if(!result || result === "") {
			askForName();
			return;
		}
		myname = result;
		// Create the MIDI controller first
		createController();
		// Start the streaming mountpoint as well
		receiveAudio();
	});
}

function createController() {
	// Attach to the Lua plugin
	janus.attach(
		{
			plugin: "janus.plugin.lua",
			opaqueId: opaqueId,
			success: function(pluginHandle) {
				controller = pluginHandle;
				Janus.log("Plugin attached! (" + controller.getPlugin() + ", id=" + controller.getId() + ")");
				// Setup the DataChannel
				var body = { request: "setup" };
				Janus.debug("Sending message (" + JSON.stringify(body) + ")");
				controller.send({ message: body });
			},
			error: function(error) {
				console.error("  -- Error attaching plugin...", error);
				bootbox.alert("Error attaching plugin... " + error);
			},
			webrtcState: function(on) {
				Janus.log("Janus says our controller WebRTC PeerConnection is " + (on ? "up" : "down") + " now");
			},
			onmessage: function(msg, jsep) {
				Janus.debug(" ::: Got a message :::", msg);
				if(msg["error"]) {
					bootbox.alert(msg["error"]);
				}
				if(jsep) {
					// Answer
					controller.createAnswer(
						{
							jsep: jsep,
							media: { audio: false, video: false, data: true },	// We only use datachannels
							success: function(jsep) {
								Janus.debug("Got SDP!", jsep);
								var body = { request: "ack" };
								controller.send({ message: body, jsep: jsep });
							},
							error: function(error) {
								Janus.error("WebRTC error:", error);
								bootbox.alert("WebRTC error... " + error.message);
							}
						});
				}
			},
			ondataopen: function(data) {
				Janus.log("The DataChannel is available!");
				$('#details').remove();
				$('#start').removeAttr('disabled').html("Stop")
					.click(function() {
						$(this).attr('disabled', true);
						janus.destroy();
					});
				// Register the name+color
				sendDataMessage({ action: "register", name: myname, color: mycolor });
				// Show the piano
				$('#piano').removeClass('hide');
				$('.white-key, .black-key')
					.on('mousedown', function(ev) {
						notes[ev.target.dataset.key] = true;
						sendDataMessage({ action: "play", note: parseInt(ev.target.dataset.key) });
					})
					.on('mouseup mouseleave', function(ev) {
						if(notes[ev.target.dataset.key] === true) {
							delete notes[ev.target.dataset.key];
							sendDataMessage({ action: "stop", note: parseInt(ev.target.dataset.key) });
						}
					});
			},
			ondata: function(data) {
				Janus.debug("We got data from the DataChannel!", data);
				handleResponse(JSON.parse(data));
			},
			oncleanup: function() {
				Janus.log(" ::: Got a cleanup notification :::");
			}
		});
}

function sendDataMessage(note) {
	controller.data({
		text: JSON.stringify(note),
		error: function(reason) {
			bootbox.alert(reason);
		},
		success: function() {
			// TODO
		}
	});
}

function handleResponse(data) {
	Janus.debug(data);
	if(data["response"] === "error") {
		bootbox.alert(data["error"]);
	} else if(data["event"]) {
		if(data["event"] === "join") {
			var id = data["id"];
			var name = data["name"];
			var color = data["color"];
			$('#players').append('<p id="p' + id + '"><span class="label" style="color: black; background:' + color + '">' + name + '</span></p>');
		} else if(data["event"] === "leave") {
			var id = data["id"];
			$('#p' + id).remove();
		} else if(data["event"] === "play") {
			var note = data["note"];
			var name = data["name"];
			var color = data["color"];
			if(!bgs[note])
				bgs[note] = { original: $('[data-key=' + note + ']').css('background'), count: 0, colors: [] };
			bgs[note].count++;
			bgs[note].colors.push(color);
			$('[data-key=' + note + ']').css('background', color);
			console.log(bgs);
		} else if(data["event"] === "stop") {
			var note = data["note"];
			var name = data["name"];
			if(!bgs[note])
				return;
			var index = bgs[note].colors.indexOf(color);
			if(index > -1)
				bgs[note].colors.splice(index, 1);
			if(bgs[note].colors.length === 0)
				$('[data-key=' + note + ']').css('background', bgs[note].original);
			else
				$('[data-key=' + note + ']').css('background', bgs[note].colors[bgs[note].colors.length-1]);
			bgs[note].count--;
			if(bgs[note].count === 0) {
				$('[data-key=' + note + ']').css('background', bgs[note].original);
				delete bgs[note];
			}
			console.log(bgs);
		}
	}
}

function receiveAudio() {
	// Attach to streaming plugin
	janus.attach(
		{
			plugin: "janus.plugin.streaming",
			opaqueId: opaqueId,
			success: function(pluginHandle) {
				streaming = pluginHandle;
				var body = { request: "watch", id: streamId };
				streaming.send({ message: body });
			},
			error: function(error) {
				Janus.error("  -- Error attaching plugin... ", error);
				bootbox.alert("Error attaching plugin... " + error);
			},
			webrtcState: function(on) {
				Janus.log("Janus says our streaming WebRTC PeerConnection is " + (on ? "up" : "down") + " now");
			},
			onmessage: function(msg, jsep) {
				Janus.debug(" ::: Got a message :::", msg);
				if(msg["error"]) {
					bootbox.alert(msg["error"]);
					return;
				}
				if(jsep) {
					Janus.debug("Handling SDP as well...", jsep);
					// Offer from the plugin, let's answer
					streaming.createAnswer(
						{
							jsep: jsep,
							// We only want recvonly audio
							media: { audioSend: false, videoSend: false, data: false },
							success: function(jsep) {
								Janus.debug("Got SDP!");
								Janus.debug(jsep);
								var body = { request: "start" };
								streaming.send({ message: body, jsep: jsep });
							},
							error: function(error) {
								Janus.error("WebRTC error:", error);
								bootbox.alert("WebRTC error... " + error.message);
							}
						});
				}
			},
			onremotestream: function(stream) {
				Janus.debug(" ::: Got a remote stream :::");
				Janus.debug(stream);
				if($('#remoteaudio').length === 0) {
					// Add the video element
					$('#piano').append('<audio class="hide" id="remoteaudio" autoplay playsinline/>');
				}
				Janus.attachMediaStream($('#remoteaudio').get(0), stream);
			},
			oncleanup: function() {
				Janus.log(" ::: Got a cleanup notification :::");
			}
		});
}

function createRandomColor() {
	return "hsla(" + ~~(360 * Math.random()) + "," + "70%," + "80%,1)"
}
