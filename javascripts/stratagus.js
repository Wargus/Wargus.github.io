$(function()  { 
	$("#menu").html("\
		<a href=index.html>Wargus</a> \
		<a href=war1gus.html>War1gus</a> \
		<a href=aleona.html>Aleona's Tales</a> \
		<a href=wyrmsun.html>Wyrmsun</a> \
		<a href=stratagus.html>Stratagus</a> \
	");

	$("#dlLinux").mouseenter(function() { $("#dlLinuxInfo").slideDown("slow"); });
	$(".dlNotLinux").mouseenter(function() { $("#dlLinuxInfo").slideUp("slow"); });




});
