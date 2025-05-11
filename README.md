# sp7-power
Microsoft Surface Pro 7 Energy and Thermal Management Script for Linux.

## The Problem
My Surface Pro 7 i7 gets very hot, which both makes the device uncomfortable to use handheld, and occasionally results in the CPU being aggressively throttled to 200MHz, half the usual lowest clock speed, making it unusable.

## My Solution
A shell script (I use zsh, should work in bash) to run as a service in the background which controls the max CPU frequency, energy performance preference, and powercap/rapl to ensure the case remains at comfortable or at least bearable temperatures to hold, while also preventing the device from overheating and causing aggressive throttling.

It also takes over low power mode for battery, switching to low power settings (platform profile, energy performance preference, energy performance bias), and also features a Low Power + Fan mode to keep the device as cool as possible (I find this particularly valuable when charging) that can be toggled without a password. This Low Power + Fan Mode is the same as the Low Power Mode used for battery, except the platform profile is set to performance for maximum fan aggressiveness.

Platform profile is only set when the state is changed – either when Low Power + Fan mode is activated, screen is locked, or charger is plugged/unplugged – which means if you want to manually control the fan level at any time you can use `surface profile set <x>` to temporarily set the fan aggressiveness until the state is changed again. Fore example, `surface profile set power` for a quiet mode. Use `surface profile list` to see options.

It switches to a lower-power energy performance preference (by default set to "lowEPP" or balance_power) when the screen is locked. In a future version I might add some sort of "Performance Lock" power mode to lock the device without going into a medium power mode.

### How it Works
A curve is defined which associates the max CPU core temperature with a max CPU clock speed. Two curve shapes are provided, linear and parabola, although having used the script for some time I definitely find linear better since it allows the CPU to remain at its best performance settings more of the time and only throttles when needed. I have a [desmos graph I use to help visualise the curve](https://www.desmos.com/calculator/a0qz23f2kj).

Rather than the temperature immediately setting the max CPU frequency, the script will gradually raise and lower the frequency. This allows the thermal throttling to ramp up slowly as the device gets warmer. Short bursts of CPU activity and even high CPU temps won't immediately trigger throttling if you don't want it to, and likewise if the temperatures have been high for a sustained period, the clock speeds will remain low for some time, allowing the device to cool even after the the demanding task that raised the temperature has stopped. 
Both the rate of increase and rate of decrease can be controlled separately, allowing you to dial in the script's responsiveness to both high and low temperatures.

The energy performance preference, which controls the tendency to set high or low frequencies within the allowed range, is set based on the current max frequency. The energy performance preference itself caps the frequency, so I like to match up the max frequency with the energy performance preference, the effect being a gradual decrease in both maximum and average frequencies as the temperature stays high for longer. For example, on my i7 SP7 balance_power caps the frequency at 3GHz, so I set the threshold to trigger that EPP ( the"lowEPPThresh" variable in the script) at 2.95GHz. 
Maybe somebody knows how to find out what each EPP does for each device; I just observed the effect myself and set the numbers manually (I have made some attempt to have the thresholds automatically scale depending on your CPU).

Finally, the Intel powercap/rapl driver is used for extreme temperatures. This is the driver `thermald` uses by default in other thermal management solutions for the Surface Pro – the NixOS module for Surface Pro contains [a default thermald configuration](https://github.com/NixOS/nixos-hardware/blob/master/microsoft/surface/surface-pro-intel/thermal-conf.xml) that uses this driver. Also see [the Linux Surface wiki entry for thermald](https://github.com/linux-surface/linux-surface/wiki/Thermald-setup-and-configuration). I find thermald difficult to configure and buggy, and regardless the powercap driver doesn't work that well at actually capping energy usage. It tends to go from doing nothing to capping the CPU at its absolute minimum frequency very fast – I don't ever need my CPU to be capped at 400MHz, it is not helpful and too slow to be useable. It also seems to cap iGPU performance (althoguh I haven't verified this), and the SP7 doesn't have a lot to spare, so I only want that in the most extreme cases – **which is how it is used in the script:**

Once the max CPU frequency is capped to a certain degree (the "powercapThresh" variable in the script), powercap will be initiated to make sure the device doesn't completely overheat and trigger aggressive throttling (on the SP7 i7 the CPU drops to 200MHz and stays there long after temperatures are cool enough). I have this powercap mode set to 16,000,000 microwatts, at which I cannot overheat the device no matter how much I try. 

### Omissions
Missing from this script is control over CPU governor. The reason for this is simple, I don't ever use the Performance governor since I am always aiming for temperatures that won't burn me if I pick up the device. With Performance governor, the energy performance preference is forced to performance, and in any task that demanding the device inevitably heats up enough for my script to lower the max freq and EPP. If you want to change the Governor through some other means that would not interfere with this script aside from overriding the energy performance preference.

There is also not much included in the way of extending battery life, but I have not actually found any way to improve the battery life beyond these basic power settings (I also use powertop but it doesn't make a noticeable difference). Turning off turbo, using TLP, auto-cpufreq, capping CPU frequencies below the base frequency, using powercap to limit power draw – none of it helps without making performance completely unusable. 
If anybody has any recommendations for battery life I would be very interested to incorporate them into the low power modes of this script.

Also, the i7 variant of the SP7 for which this script was written has a fan – it might not make sense to keep the platform profile on performance for other devices.

## Dependencies
```
lm_sensors
gawk
bc
powercap
```

There could be more, especially if your distro doesn't use GNU Core Utilities.

Not compatible with power-profiles-daemon, the daemon your desktop environment likely uses to switch between power, balanced and performance power profiles.

Requires root priveliges.

## Notes and Compatibility
For zsh shell, shouldn't have any issues with bash.

**Please read through the script before use and modify for your device, distro and preferences**. It has only been tested on my device and is designed for my narrow use-case. If your Surface device has for example a different number of cores, you may need to alter the script. There are options you might want to tweak, and it is important to check that the paths in the Basic Definitions section are valid on your device.

I have tried to make the script easy to adapt but I am just sharing my solution, I'm not going to troubleshoot for your device.

## Getting Low Power + Fan Mode to work
Make sure to input the directory and filename (in the Basic Definitions section of the script) of the file in your home folder which tracks low power fan mode. You may get errors if you don't, even if you don't need the feature.
You can then create another script which toggles between "yes" for Low Power + Fan Mode and "No" for default Power Mode (Performance on AC, Low Power on battery). My script looks like this (you might need a shebang depending on where you run it from):

```
pathToFile=<path/to/file>

if [[ $(cat $pathToFile) = "no" ]]; then
  echo "yes" | tee $pathToFile
  notify-send "Low Power + Fan Mode Enabled"
else
  echo "no" | tee $pathToFile
  notify-send "Low Power + Fan Mode Disabled"
fi
```
You will need to install `libnotify` to use notifysend 
