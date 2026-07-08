<html>
<! Copyright (c) Realtek Semiconductor Corp., 2003. All Rights Reserved. ->
<head>
<meta http-equiv="Content-Type" content="text/html" charset="utf-8">
<title>OMCIInfo</title>
<script type="text/javascript" src="share.js">
</script>
<script>

var omci_tm_opt_value = 2;
var omcc_ver_value = 128;
var omci_olt_mode_value = "1";

function applyclick()
{
 if (document.formOmciInfo.omci_sw_ver1.value=="") {
  alert('OMCI software version 1 cannot be empty');
  document.formOmciInfo.omci_sw_ver1.focus();
  return false;
 }
 if (document.formOmciInfo.omci_sw_ver2.value=="") {
  alert('OMCI software version 2 cannot be empty');
  document.formOmciInfo.omci_sw_ver2.focus();
  return false;
 }
 if (document.formOmciInfo.cwmp_productclass.value=="") {
  alert('CWMP Product Class cannot be empty');
  document.formOmciInfo.cwmp_productclass.focus();
  return false;
 }
 if (document.formOmciInfo.cwmp_hw_ver.value=="") {
  alert('HW version cannot be empty');
  document.formOmciInfo.cwmp_hw_ver.focus();
  return false;
 }

 return true;
}

function on_change()
{
 with (document.forms[0])
 {
  if(omci_olt_mode_value == 0){
   omci_tm_opt.value = omci_tm_opt_value;
   omcc_ver.value = omcc_ver_value;
  }
 }
}

function on_init()
{
 with (document.forms[0])
 {
  omci_tm_opt.value = omci_tm_opt_value;
  omcc_ver.value = omcc_ver_value;
  //if(omci_olt_mode_value == 0)
  //	apply.style.display = "none";
 }

}
</script>
</head>

<body onLoad="on_init();">
<blockquote>
<h2><font color="#0000FF">OMCIInfo</font></h2>
<form action=/boaform/admin/formOmciInfo method=POST name="formOmciInfo">
<table border=0 width="500" cellspacing=4 cellpadding=0>
  <tr><td><font size=2>
  </font></td></tr>
  <tr><td><hr size=1 noshade align=top></td></tr>
</table>
<table border=0 width="500" cellspacing=4 cellpadding=0>
<tr>
      <td width="40%"><font size=2><b>OMCI Vendor ID</b></td>
      <td width="60%"><input type="text" name="omci_vendor_id" size="14" maxlength="4" value="HWTC"></td>
</tr>
<tr>
      <td width="40%"><font size=2><b>OMCI software version 1</b></td>
      <td width="60%"><input type="text" name="omci_sw_ver1" size="14" maxlength="14" value="V1R007C00S001" ></td>
</tr>
<tr>
      <td width="40%"><font size=2><b>OMCI software version 2</b></td>
      <td width="60%"><input type="text" name="omci_sw_ver2" size="14" maxlength="14" value="V1R007C00S001" ></td>
</tr>
<tr>
      <td width="40%"><font size=2><b>OMCC version</b></td>
      <td width="60%"><!--<input type="text" name="omcc_ver" size="40" maxlength="40" value="128">-->
      <select name="omcc_ver"  onChange="on_change()">
      <option value="128" > 0x80</option>
      <option value="129" > 0x81</option>
      <option value="130" > 0x82</option>
      <option value="131" > 0x83</option>
      <option value="132" > 0x84</option>
      <option value="133" > 0x85</option>
      <option value="134" > 0x86</option>
      <option value="150" > 0x96</option>
      <option value="160" > 0xA0</option>
      <option value="161" > 0xA1</option>
      <option value="162" > 0xA2</option>
      <option value="163" > 0xA3</option>
      <option value="176" > 0xB0</option>
      <option value="177" > 0xB1</option>
      <option value="178" > 0xB2</option>
      <option value="179" > 0xB3</option>
      </select></td>
</tr>
<tr>
      <td width="40%"><font size=2><b>Traffic Managament option</b></td>
      <td width="60%"><!--<input type="text" name="omci_tm_opt" size="40" maxlength="40" value="2">-->
    <select name="omci_tm_opt"  onChange="on_change()">
 <option value="0" > 0</option>
 <option value="1" > 1 </option>
 <option value="2" > 2 </option>
 </select></td>
</tr>
<tr>
      <td width="40%"><font size=2><b>CWMP Product Class</b></td>
      <td width="60%"><input type="text" name="cwmp_productclass" size="20" maxlength="20" value="EG8145X6-10" ></td>
</tr>
<tr>
      <td width="40%"><font size=2><b>HW version</b></td>
      <td width="60%"><input type="text" name="cwmp_hw_ver" size="14" maxlength="14" value="343D.D" ></td>
</tr>
</table>
<br>
      <input type="submit" value="Apply Changes" name="apply" onClick="return applyclick()">&nbsp;&nbsp;
      <input type="hidden" value="/omci_info.asp" name="submit-url">
</form>
</blockquote>
</body>
</html>
