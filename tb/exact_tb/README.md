This testbenches are applicable for all designs including both MXFP8 and MXFP6. 
Only changes needed are on parameters:

* parameter N = 32;

Change N if you want to test different sized Systolic Array

* parameter exp_width = 4;  

This is E4 in MXFP8_**E4**M3, you need to change it accordingly to the desired format (e.g MXFP6_E3M2 parameter exp_width = 3;)

* parameter man_width = 3;   

This is M3 in MXFP8_E4**M3**, you need to change it accordingly to the desired format (e.g MXFP6_E3M2 parameter man_width = 2;)
