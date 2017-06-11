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

    // Liberally adapted from http://jsfiddle.net/bN4qu/5/
    (function(sidebarelement) {
        let $el = $(sidebarelement);
        var viewport_height,
            smart_sticky_is_active = false,
            current_translate = 0,
            element_height,
            element_padding_bottom,
            last_viewport_top = document.documentElement.scrollTop || document.body.scrollTop;

        function resetStyle() {
            sidebarelement.style = "";
        }

        function smartStick(element, translation) {
            requestAnimationFrame(function () {
                element.css({
                    "transform": "translate(0, " + translation + "px)",
                    "position": "relative"
                });
            });
        }

        function updateElementDimensions() {
            element_height = $el.outerHeight();
            element_padding_bottom = parseInt($el.css("padding-bottom"));
        }
        setInterval(updateElementDimensions, 1000);

        function onResize() {
            viewport_height = $(window).height();
            resetStyle();
            updateElementDimensions();
            smart_sticky_is_active = $el.css("position") == "fixed";
            if (smart_sticky_is_active) {
                smartStick($el, current_translate);
            }
        }
        onResize();
        $(window).on('resize', onResize);

        $(window).scroll(function() {
            if (!smart_sticky_is_active) {
                return;
            }

            var new_translation = null;
            let viewport_top = document.documentElement.scrollTop || document.body.scrollTop,
                viewport_bottom = viewport_top + viewport_height,
                is_scrolling_up = viewport_top < last_viewport_top;
            last_viewport_top = viewport_top;

            if (element_height < viewport_height) {
                // if the element fits completely, we snap
                current_translate = 0;
                requestAnimationFrame(resetStyle);
                return;
            }

            if (is_scrolling_up && viewport_top < current_translate) {
                // if we are scrolling up and the top of the viewport is
                // higher than the element, we let it follow the viewport
                // (stick to top)
                new_translation = viewport_top;
            } else if (!is_scrolling_up &&
                       viewport_bottom > (element_height + current_translate + element_padding_bottom)) {
                // if we are scrolling down and the bottom of the viewport
                // is lower than the element's bottom, we let it follow
                // (stick to bottom)
                new_translation = viewport_bottom - element_height;
            }
            if (new_translation !== null) {
                current_translate = new_translation;
                smartStick($el, current_translate);
            }
        });
    })($("header")[0]);

    // Transform some JSON data recursively into nested div elements
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
    }
    setInterval(getMetaServers, 5000);
});
