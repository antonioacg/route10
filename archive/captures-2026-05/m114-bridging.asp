<html>
<! Copyright (c) Realtek Semiconductor Corp., 2003. All Rights Reserved. ->
<head>
<meta http-equiv="Content-Type" content="text/html" charset="utf-8">
<title>BridgingConfiguration</title>
<script type="text/javascript" src="share.js">
</script>
<SCRIPT>
function saveChanges()
{
 if (checkDigit(document.bridge.ageingTime.value) == 0) {
  alert('Invalid ageing time!');
  document.bridge.ageingTime.focus();
  return false;
 }
 return true;
}

function fdbClick(url)
{
 var wide=600;
 var high=400;
 if (document.all)
  var xMax = screen.width, yMax = screen.height;
 else if (document.layers)
  var xMax = window.outerWidth, yMax = window.outerHeight;
 else
    var xMax = 640, yMax=480;
 var xOffset = (xMax - wide)/2;
 var yOffset = (yMax - high)/3;

 var settings = 'width='+wide+',height='+high+',screenX='+xOffset+',screenY='+yOffset+',top='+yOffset+',left='+xOffset+', resizable=yes, toolbar=no,location=no,directories=no,status=no,menubar=no,scrollbars=yes';

 window.open( url, 'FDBTbl', settings );
}

</SCRIPT>
</head>

<body>
<blockquote>
<h2><font color="#0000FF">BridgingConfiguration</font></h2>

<form action=/boaform/formBridging method=POST name="bridge">
<table border=0 width="500" cellspacing=4 cellpadding=0>
  <tr><td><font size=2>
    This page is used to configure the bridge parameters. Here you can change the settings or view some information on the bridge and its attached ports.
  </font></td></tr>
  <tr><td><hr size=1 noshade align=top></td></tr>
</table>
<table border=0 width="500" cellspacing=4 cellpadding=0>

  <tr>
      <td width="30%"><font size=2><b>Ageing Time:</b></td>
      <td width="70%"><input type="text" name="ageingTime" size="15" maxlength="15" value=7200> (seconds)</td>
  </tr>

  <tr>
      <td width="30%"><font size=2><b>802.1d Spanning Tree:</b></td>
      <td width="35%">
       <input type="radio" value="0" name="stp" checked>Disabled&nbsp;&nbsp;
      <input type="radio" value="1" name="stp" >Enabled
      </td>
  </tr>
</table>
  <br>
      <input type="submit" value="Apply Changes" name="save" onClick="return saveChanges()">&nbsp;&nbsp;
      <input type="button" value="Show MACs" name="fdbTbl" onClick="fdbClick('/fdbtbl.asp')">
      <input type="hidden" value="/bridging.asp" name="submit-url">
 </form>
</blockquote>
</body>

</html>
