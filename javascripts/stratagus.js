$(function()  { 
	$("#menu").html("\
		<a href=index.html>Wargus</a> \
		<a href=war1gus.html>War1gus</a> \
		<a href=aleona.html>Aleona's Tales</a> \
		<a href=wyrmsun.html>Wyrmsun</a> \
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
	$(".dlNotLinux").mouseenter(function() { 
		$("#dlLinuxStableInfo").slideUp("slow"); 
		$("#dlLinuxUnstableInfo").slideUp("slow"); 
	});




});
