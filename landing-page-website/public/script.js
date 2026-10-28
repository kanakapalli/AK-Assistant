(function () {
  // Writing tools demo
  var outputs = {
    grammar: "Hey, can you send me the report by Friday? I need it for the client meeting. Thanks!",
    email: "Hi,\n\nCould you send me the report by Friday? I need it for the client meeting.\n\nThanks,",
    pro: "Could you please send me the report by Friday? I need it for the client meeting. Thank you.",
    rude: "Send me the report by Friday. I need it for the client meeting, so don't make me ask twice."
  };
  var after = document.getElementById("after");
  var tabs = Array.prototype.slice.call(document.querySelectorAll(".tab"));
  tabs.forEach(function (tab) {
    tab.addEventListener("click", function () {
      tabs.forEach(function (t) { t.setAttribute("aria-selected", String(t === tab)); });
      after.textContent = outputs[tab.dataset.k];
    });
  });

  // Hero popup: Listening → Transcribing → Pasted, on a loop. The resting frame is already complete.
  if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  var label = document.getElementById("islandLabel");
  var time = document.getElementById("islandTime");
  var text = document.getElementById("islandText");
  var bars = document.getElementById("islandBars");
  var dot = document.getElementById("islandDot");
  var typed = document.getElementById("typed");
  var spoken = "can you push the release notes to the channel before the standup";
  var final = "Can you push the release notes to the channel before the standup?";
  var words = spoken.split(" ");
  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  async function loop() {
    while (true) {
      label.textContent = "Listening…"; bars.hidden = false; dot.hidden = false; time.hidden = false;
      typed.textContent = "";
      for (var i = 1; i <= words.length; i++) {
        text.textContent = words.slice(0, i).join(" ");
        time.textContent = "0:0" + Math.min(9, Math.floor(i / 3));
        await wait(260);
      }
      await wait(600);
      label.textContent = "Transcribing…"; bars.hidden = true; dot.hidden = true; time.hidden = true;
      await wait(700);
      label.textContent = "Pasted into Slack";
      text.textContent = final;
      for (var c = 1; c <= final.length; c++) { typed.textContent = final.slice(0, c); await wait(14); }
      await wait(3200);
    }
  }
  setTimeout(loop, 2500);
})();
