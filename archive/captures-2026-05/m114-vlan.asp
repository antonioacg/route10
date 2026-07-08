<html>
<! Copyright (c) Realtek Semiconductor Corp., 2003. All Rights Reserved. ->
<head>
<meta http-equiv="Content-Type" content="text/html" charset="utf-8">
<title>VLAN Settings</title>
<script type="text/javascript" src="share.js">
</script>
<SCRIPT>
var vlan_manu_pri= 0;
function vlan_cfg_type_change()
{
 with (document.forms[0])
 {
  if(vlan_cfg_type[0].checked == true){
   disableRadioGroup(vlan_manu_mode);
   vlan_manu_tag_pri.disabled = true;
   disableTextField(vlan_manu_tag_vid);
  }
  else{
   enableRadioGroup(vlan_manu_mode);
   vlan_manu_mode_change();
  }
 }
}
function vlan_manu_mode_change()
{
 with (document.forms[0])
 {
  if(vlan_manu_mode[1].checked == true){
   vlan_manu_tag_pri.disabled = false;
   enableTextField(vlan_manu_tag_vid);
  }
  else{
   vlan_manu_tag_pri.disabled = true;
   disableTextField(vlan_manu_tag_vid);
  }
 }
}
function on_init()
{
 with (document.forms[0])
 {
  vlan_manu_tag_pri.value = vlan_manu_pri + 1;
  if(vlan_cfg_type[0].checked == true)
   refresh.disabled = false;
  else
   refresh.disabled = true;

 }
 vlan_cfg_type_change();

}
function saveChanges()
{
 with (document.forms[0])
 {
  if (vlan_cfg_type[1].checked == true) {
   if(vlan_manu_mode[1].checked == true){
    if(vlan_manu_tag_vid.value == ""){
     alert("VID cannot be empty!");
     vlan_manu_tag_vid.focus();
     return false;
    }
    if(vlan_manu_tag_pri.value == 0){
     alert("VLAN priority cannot be empty!");
     vlan_manu_tag_pri.focus();
     return false;
    }
   }
  }
 }

 return true;
}
</SCRIPT>
</head>
<body onLoad="on_init();">
<blockquote>
<h2><font color="#0000FF">VLAN Settings</font></h2>

<form action=/boaform/formVlan method=POST name="vlan">
<table border=0 width="500" cellspacing=4 cellpadding=0>
  <tr><td><font size=2>
    This page is used to configure VLAN settings of your Device.
  </font></td></tr>
  <tr><td><hr size=1 noshade align=top></td></tr>
</table>
<table border=0 width="500" cellspacing=4 cellpadding=0>
<tr>
<td width="10%"><input type="radio" name="vlan_cfg_type" value=0 OnClick="vlan_cfg_type_change()"  ></td>
<td width="10%"><font size=2><b>Auto</b></td>
<td><input type="submit" value="Refresh" name="refresh"></td>
</tr>
<tr style="vertical-align:top"><td height="50px" width="10%"></td><td height="50px" colspan=2><table border="0"></table></td></tr>
<tr>
<td width="10%"><input type="radio" name="vlan_cfg_type" value=1 OnClick="vlan_cfg_type_change()" checked></td>
<td colspan="2" width="90%"><font size=2><b>Manual</b></td>
</tr>
</table>
<table border=0 width="500" cellspacing=4 cellpadding=0>
<tr>
<td width="10%"></td>
<td width="10%"><input type="radio" name="vlan_manu_mode" value=0 OnClick="vlan_manu_mode_change()" ></td>
<td width="80%"><font size=2><b>Transparent Mode</b></td>
</tr>
<tr>
<td width="10%"></td>
<td width="10%"><input type="radio" name="vlan_manu_mode" value=1 OnClick="vlan_manu_mode_change()" checked></td>
<td width="80%"><font size=2><b>Tagging Mode</b>:
<input type="text" name="vlan_manu_tag_vid" size="5" maxlength="5" value="1011">[0~4095]&nbsp;&nbsp;
VLAN Priority:
 <select style="WIDTH: 60px" name="vlan_manu_tag_pri">
 <option value="0" > </option>
 <option value="1" > 0 </option>
 <option value="2" > 1 </option>
 <option value="3" > 2 </option>
 <option value="4" > 3 </option>
 <option value="5" > 4 </option>
 <option value="6" > 5 </option>
 <option value="7" > 6 </option>
 <option value="8" > 7 </option>
 </select>

</td>
</tr>
<tr>
<td width="10%"></td>
<td width="10%"><input type="radio" name="vlan_manu_mode" value=2 OnClick="vlan_manu_mode_change()" ></td>
<td width="80%"><font size=2><b>Remote Access Mode</b></td>
</tr>
<tr>
<td width="10%"></td>
<td width="10%"><input type="radio" name="vlan_manu_mode" value=3 OnClick="vlan_manu_mode_change()" ></td>
<td width="80%"><font size=2><b>Special Case Mode</b></td>
</tr>
</table>
<br>
      <input type="submit" value="Apply Changes" name="save" onClick="return saveChanges()">
      <input type="hidden" value="/vlan.asp" name="submit-url">
</form>
</blockquote>
</body>

</html>
