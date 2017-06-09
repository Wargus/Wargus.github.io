$(function()  {
    $("#menu").html("\
        <a href=index.html>Wargus</a> \
        <a href=war1gus.html>War1gus</a> \
        <a href=aleona.html>Aleona's Tales</a> \
        <a href=wyrmsun.html>Wyrmsun</a> \
        <a href=stargus.html>Stargus (Pre-Alpha)</a> \
        <a href=stratagus.html>Stratagus</a> \
        <a href=faq.html>FAQ</a> \
    ");

    $("#dlLinuxStable").mouseenter(function() {
        $("#dlLinuxUnstableInfo").slideUp("slow");
        $("#dlLinuxStableInfo").slideDown("slow");
    });
    $("#dlLinuxUnstable").mouseenter(function() {
        $("#dlLinuxStableInfo").slideUp("slow");
        $("#dlLinuxUnstableInfo").slideDown("slow");
    });

    // $(".dlNotLinux").mouseenter(function() {
    //  $("#dlLinuxStableInfo").slideUp("slow");
    //  $("#dlLinuxUnstableInfo").slideUp("slow");
    // });

    $("body").on("click", ".closeImg",function() {
        $("#dlLinuxStableInfo").slideUp("fast");
        $("#dlLinuxUnstableInfo").slideUp("fast");
    });

    function printJSON(data) {
        var jsonDiv = document.createElement("div");
        for (var key in data) {
            var value = data[key];
            var keyDiv = document.createElement("div");
            var nameDiv = document.createElement("div");
            nameDiv.innerText = key;
            nameDiv.classList.add("key");
            keyDiv.appendChild(nameDiv);
            if (typeof(value) == "object") {
                keyDiv.appendChild(printJSON(value));
            } else {
                var valueSpan = document.createElement("span");
                valueSpan.innerText = value;
                keyDiv.appendChild(valueSpan);
            }
            keyDiv.classList.add(key);
            jsonDiv.appendChild(keyDiv);
        }
        return jsonDiv;
    }

    function getMetaServers() {
        var parentDiv = $("#metaservers");
        if (parentDiv.length > 0) {
            $.getJSON("https://metaservernet.herokuapp.com/", function (data) {
                var metaserverDivs = printJSON(data);
                parentDiv.empty();
                parentDiv.append(metaserverDivs);
            });
        }
        setTimeout(getMetaServers, 5000);
    }
    setTimeout(getMetaServers, 1000);
});
