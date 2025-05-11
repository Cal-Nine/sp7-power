!# /bin/sh


set +e



sleep 5



# Basic Definitions #

lowPowerFanDir= # Directory in which you'd like the file that tracks Low Power + Fan Mode to reside. Do not include slash at the end.
lowPowerFanFile= # Filename of file that tracks Low Power + Fan Mode

platformProfileFile=/sys/firmware/acpi/platform_profile
noTurboFile=/sys/devices/system/cpu/intel_pstate/no_turbo
onACFile=/sys/class/power_supply/ADP1/online

govWrite=/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
EPPWrite=/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
EPBiasWrite=/sys/devices/system/cpu/cpu*/power/energy_perf_bias
maxFreqWrite=/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq

govRead=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
EPPRead=/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
EPBiasRead=/sys/devices/system/cpu/cpu0/power/energy_perf_bias
maxFreqRead=/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq

cpuInfoMaxFreq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
cpuInfoMinFreq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq)
cpuInfoBaseFreq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/base_frequency)



##### OPTIONS #####



      updateInterval=2 # For Power Mode

# Performance Mode

      governor=powersave # cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
      energyPerfBias=9 # 0-15 (where 0 = maximum performance and 15 = maximum power saving)
      platformProfile=performance # cat /sys/firmware/acpi/platform_profile_choices
      powercapMicrowatts=65000000
      powercapMicroseconds=12000000

# Thermal Management Settings

      initClock=3000000 # Max clock speed when service starts. Can be set to "currentClock" (no quotes)

  # Throttling Curve

      # https://www.desmos.com/calculator/a0qz23f2kj
      lineShape=linear # Options: "linear" or "parabola". See desmos graph for visualisation.
      maxClock=$cpuInfoMaxFreq # Your CPU's highest available max freq, or whatever you'd like it to be within its range. The curve can go above this in order to add a delay before thermal control starts.
      minClock=$cpuInfoBaseFreq # Your CPU's lowest available max freq, or whatever you'd like it to be within its range (e.g. its base freq). The curve can go below this in order to add a delay before thermal control is able to release from the most intense.
      highClock=$(echo "$maxClock + 500000" | bc) # The virtual maximum clock speed. Setting this higher than maxClock introduces a delay before the max freq starts to be reduced
      lowClock=$(echo "$minClock - 150000" | bc) # Max CPU frequency at most aggressive thermal throttling. Setting this lower than minClock introduces a delay before max freq starts to be raised.
      highTemp=70 # Temperature at which lowClock will be reached
      lowTemp=55 # The temperature at which maximum CPU frequency begins to parabolically decrease as temperature increases, up to highTemp and lowClock values
      tp=$highClock # parabola turning point or line intersect. Will often make sense to set this to $highClock

  # Follow Curve

      waitToIncrease=18 # Wait in seconds before increasing max CPU frequency ("waitToDoNothing" is whichever is lower). Rule of thumb, don't put one more than 3x the value of the other.
      waitToDecrease=9 # Wait in seconds before decreasing max CPU frequency ("waitToDoNothing" is whichever is lower). Rule of thumb, don't put one more than 3x the value of the other.
      clockIncrement=50000 # The increment by which max CPU frequency is increased or reduced after each wait Not all inputs will be valid.
      ignoreMaxFreqAbove=$(echo "$maxClock - 400000" | bc) # Ignore the Max CPU Frequency value above a certain clock speed, relying on EPP and powercap instead to control temperatures

  # EPP (Energy Performance Preference)

      highEPP=performance
      midEPP=balance_performance
      midEPPThresh=$maxClock # At what throttled freq to switch to midEPP
      lowEPP=balance_power
      lowEPPThresh=$(echo "(($cpuInfoMaxFreq * 3 / 4) + ($clockIncrement / 2)) / $clockIncrement * $clockIncrement" | bc) # At what throttled freq to switch to lowEPP. I like to set it to one $clockIncrement below where lowEPP would naturally cap the frequency which just so happens on my SP7 i7 CPU to be 3/4 of the max freq when rounded to $clockIncrement
      floorEPP=power
      floorEPPThresh=$(echo "$minClock + 450000" | bc) # At what throttled freq to switch to lowEPP

  # Use Powercap at very hot temps

      powercapHotMicrowatts=16000000 # This setting seems like it can always prevent the aggressive throttling that happens when the device overheats, so if you find it happening, double check it is actually getting to the powercapThresh before overheating and if it isn't either raise the threshold or make the curve or waitToDecrease more aggressive
      powercapThresh=1300000



##### IMPLEMENTATION #####



# Setup #

echo "$governor" | tee $govWrite
echo "$midEPP" | tee $EPPWrite
echo "$energyPerfBias" | tee $EPBiasWrite
echo "$platformProfile" | tee $platformProfileFile
echo "0" | tee $noTurboFile
powercap-set intel-rapl -z 0 -c 0 -l $powercapMicrowatts -s $powercapMicroseconds
powercap-set intel-rapl-mmio -z 0 -c 0 -l $powercapMicrowatts -s $powercapMicroseconds
mkdir -p $lowPowerFanDir
echo "no" | tee $lowPowerFanDir/$lowPowerFanFile

if [[ "$initClock" = "currentClock" ]]; then
  currentClock=$(cat $maxFreqRead)
else
  currentClock=$initClock
fi
previousClock=$currentClock

if [[ "$waitToIncrease" -ge "$waitToDecrease" ]]; then
  extraWaitHigher=$(echo "scale=4; $waitToIncrease - $waitToDecrease" | bc) # Using scale=4 was meant to allow for decimals in the wait times, but it dosn't seem to work. Haven't looked into it.
  extraWaitLower=0
  normalWait=$waitToDecrease
else
  extraWaitLower=$(echo "scale=4; $waitToDecrease - $waitToIncrease" | bc)
  extraWaitHigher=0
  normalWait=$waitToIncrease
fi

previouslyLocked=no
previousBattery=no
prevLowPowerFan=no

echo "Setup Complete"



### Set Platform Profile ###

while true; do

  # Check if Low Power Fan Mode #

  lowPowerFan=$(cat $lowPowerFanDir/$lowPowerFanFile)



  # Check if Locked #

  sessionID=$(loginctl | grep user | awk '{print $1}' | head -n 1) # This means the first user to log in will be the one that controls "$locked"
  if [[ $(loginctl show-session $sessionID -p LockedHint) = "LockedHint=yes" ]]; then
    locked=yes
  else
    locked=no
  fi



  # Check if on Battery #

  if [[ $(cat $onACFile) = 1 ]]; then
    onBattery=no
  else
    onBattery=yes
  fi



  # Set Platform Profile
  if [[ "$onBattery" != "$previousBattery" ]] || [[ "$lowPowerFan" != "$prevLowPowerFan" ]]; then 
    if [[ "$lowPowerFan" != "yes" ]]; then
      echo "$platformProfile" | tee $platformProfileFile
      if [[ "$onBattery" = "no" ]]; then
        echo "Switching to Performance Power Mode"
      else
        echo "Switching to Low Power Fan Mode"
      fi
    else
      echo "power" | tee $platformProfileFile
      echo "Switching to Low Power Mode"
    fi
  fi



  previousBattery=$onBattery
  prevLowPowerFan=$lowPowerFan



  sleep $updateInterval

done &



### Thermal Management, EPP, Powercap ###

while true; do

  # Get Temperature #

  temp=$(sensors | grep -A 3 "Core 0" | awk '{print $3}' | tr -d '+°C' | sort -n | tail -n 1) # Finds max core temp. You may need to use a different method to get the temp on different systems – this won't work if you have fewer than 4 cores, and will ignore cores if you have more than 4
  tempVal=$(echo "$temp / 1" | bc)
  echo "Temp. = $tempVal°C"



  # Calculate Target Clock #

  if [[ "$lineShape" = "linear" ]]; then
    targetClock=$(echo "($tp * $highTemp - $tp * $tempVal - $lowClock * $lowTemp + $lowClock * $tempVal) / ($highTemp - $lowTemp)" | bc)
  else
    if [[ "$lineShape" = "parabola" ]]; then
      targetClock=$(echo "$tp - (($tp - $lowClock) * ($lowTemp - $tempVal)^2) / (($highTemp - $lowTemp)^2)" | bc)
    else
      echo "Unrecognised lineShape"
    fi
  fi
  targetClockRounded=$(echo "($targetClock + ($clockIncrement / 2)) / $clockIncrement * $clockIncrement" | bc) # This should round by clockIncrement
  if [[ "$tempVal" -gt "$highTemp" ]]; then
    targetClock=$lowClock
    targetClockRounded=$lowClock
  else
    if [[ "$tempVal" -lt "$lowTemp" ]]; then
      targetClock=$highClock
      targetClockRounded=$highClock
    fi
  fi
  echo "Target Max Frequency = $targetClock"
  echo "Target Max Frequency Rounded = $targetClockRounded"



  # Add extra wait for overall correct waitToIncrease and waitToDecrease #

  if [[ "$targetClockRounded" -ne "$previousClock" ]]; then

    if [[ "$targetClockRounded" -gt "$previousClock" ]]; then
      sleep $extraWaitHigher
    else
      sleep $extraWaitLower
    fi



    # Calculate Target Clock Again #

    if [[ "$lineShape" = "linear" ]]; then
      targetClock=$(echo "($tp * $highTemp - $tp * $tempVal - $lowClock * $lowTemp + $lowClock * $tempVal) / ($highTemp - $lowTemp)" | bc)
    else
      if [[ "$lineShape" = "parabola" ]]; then
        targetClock=$(echo "$tp - (($tp - $lowClock) * ($lowTemp - $tempVal)^2) / (($highTemp - $lowTemp)^2)" | bc)
      else
        echo "Unrecognised lineShape"
      fi
    fi
    targetClockRounded=$(echo "($targetClock + ($clockIncrement / 2)) / $clockIncrement * $clockIncrement" | bc) # This should round by clockIncrement
    if [[ "$tempVal" -gt "$highTemp" ]]; then
      targetClock=$lowClock
      targetClockRounded=$lowClock
    else
      if [[ "$tempVal" -lt "$lowTemp" ]]; then
        targetClock=$highClock
        targetClockRounded=$highClock
      fi
    fi
    echo "Target Max Frequency = $targetClock"
    echo "Target Max Frequency Rounded = $targetClockRounded"
  


    # Set Maximum CPU Frequency #

    if [[ "$targetClockRounded" -ne "$previousClock" ]]; then    # Here
      if [[ "$targetClockRounded" -gt "$previousClock" ]]; then  # and here, use $currentClock instead of $previousClock? They should always be the same at this point I think but it might just be more readable to use $currentClock
        currentClock=$(expr $previousClock + $clockIncrement)
        echo "Raising virtual max freq to:"
        echo "$currentClock"
        if [[ "$currentClock" -gt "$ignoreMaxFreqAbove" ]] || [[ "$currentClock" -gt "$maxClock" ]] ; then
          echo "Setting max freq to highClock:"
          echo $maxClock | tee $maxFreqWrite
        else
          if [[ "$currentClock" -lt "$minClock" ]]; then
            echo "Setting max freq to minClock:"
            echo $minClock | tee $maxFreqWrite
          else
            echo "Raising max freq to:"
            echo $currentClock | tee $maxFreqWrite
          fi
        fi
        previousClock=$currentClock
      else
        currentClock=$(expr $previousClock - $clockIncrement)
        echo "Lowering virtual max freq to:"
        echo "$currentClock"
        if [[ "$currentClock" -gt "$ignoreMaxFreqAbove" ]] || [[ "$currentClock" -gt "$maxClock" ]] ; then
          echo "Setting max freq to highClock:"
          echo $maxClock | tee $maxFreqWrite
        else
          if [[ "$currentClock" -lt "$minClock" ]]; then
            echo "Setting max freq to minClock:"
            echo $minClock | tee $maxFreqWrite
          else
            echo "Lowering max freq to:"
            echo $currentClock | tee $maxFreqWrite
          fi
        fi
        previousClock=$currentClock
      fi
    fi



  fi



  # Check if Low Power Fan Mode #

  lowPowerFan=$(cat '/home/hailey/Info, Configuration, Keyboard Shortcuts/lowPowerFanMode') ### NOTE Path Missing from Basic Definitions



  # Check if Locked #

  sessionID=$(loginctl | grep user | awk '{print $1}' | head -n 1) # This means the first user to log in will be the one that controls "$locked"
  if [[ $(loginctl show-session $sessionID -p LockedHint) = "LockedHint=yes" ]]; then
    locked=yes
  else
    locked=no
  fi



  # Check if on Battery #

  if [[ $(cat $onACFile) = 1 ]]; then
    onBattery=no
  else
    onBattery=yes
  fi



  # Set EPP #
  echo "EPP:"
  if [[ "$lowPowerFan" = "yes" ]] || [[ "$onBattery" = "yes" ]]; then
    echo "$floorEPP" | tee $EPPWrite
  else
    if [[ "$locked" = "yes" ]]; then
      if [[ "$currentClock" -le "$floorEPPThresh" ]]; then
        echo "$floorEPP" | tee $EPPWrite
      else
        echo "$lowEPP" | tee $EPPWrite
      fi
    else
      if [[ "$currentClock" -le "$midEPPThresh" ]]; then
        if [[ "$currentClock" -le "$lowEPPThresh" ]]; then
          if [[ "$currentClock" -le "$floorEPPThresh" ]]; then
            echo "$floorEPP" | tee $EPPWrite
          else
            echo "$lowEPP" | tee $EPPWrite
          fi
        else
          echo "$midEPP" | tee $EPPWrite
        fi
      else
        echo "$highEPP" | tee $EPPWrite
      fi
    fi
  fi

  

  # Set Powercap #

  if [[ "$currentClock" -le "$powercapThresh" ]]; then
    powercap-set intel-rapl -z 0 -c 0 -l $powercapHotMicrowatts -s $powercapMicroseconds
    powercap-set intel-rapl-mmio -z 0 -c 0 -l $powercapHotMicrowatts -s $powercapMicroseconds
  else
    powercap-set intel-rapl -z 0 -c 0 -l $powercapMicrowatts -s $powercapMicroseconds
    powercap-set intel-rapl-mmio -z 0 -c 0 -l $powercapMicrowatts -s $powercapMicroseconds
  fi



  previouslyLocked=$locked
  previousBattery=$onBattery
  prevLowPowerFan=$lowPowerFan



  sleep $normalWait
  echo ""

done
