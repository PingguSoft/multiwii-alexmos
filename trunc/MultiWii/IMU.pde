
void computeIMU () {
  uint8_t axis;
  static int16_t gyroADCprevious[3] = {0,0,0};
  int16_t gyroADCp[3];
  int16_t gyroADCinter[3];
//  static int16_t lastAccADC[3] = {0,0,0};
  static uint32_t timeInterleave = 0;
#if defined(TRI)
  static int16_t gyroYawSmooth = 0;
#endif

  //we separate the 2 situations because reading gyro values with a gyro only setup can be acchieved at a higher rate
  //gyro+nunchuk: we must wait for a quite high delay betwwen 2 reads to get both WM+ and Nunchuk data. It works with 3ms
  //gyro only: the delay to read 2 consecutive values can be reduced to only 0.65ms
  if (!ACC && nunchuk) {
    annexCode();
    while((micros()-timeInterleave)<INTERLEAVING_DELAY) ; //interleaving delay between 2 consecutive reads
    timeInterleave=micros();
    WMP_getRawADC();
    getEstimatedAttitude(); // computation time must last less than one interleaving delay
    #if BARO
      getEstimatedAltitude();
    #endif 
    while((micros()-timeInterleave)<INTERLEAVING_DELAY) ; //interleaving delay between 2 consecutive reads
    timeInterleave=micros();
    while(WMP_getRawADC() != 1) ; // For this interleaving reading, we must have a gyro update at this point (less delay)

    for (axis = 0; axis < 3; axis++) {
      // empirical, we take a weighted value of the current and the previous values
      // /4 is to average 4 values, note: overflow is not possible for WMP gyro here
      gyroData[axis] = (gyroADC[axis]*3+gyroADCprevious[axis]+2)/4;
      gyroADCprevious[axis] = gyroADC[axis];
    }
  } else {
    if (ACC) {
      ACC_getADC();
      getEstimatedAttitude();
      if (BARO) getEstimatedAltitude();
    }
    if (GYRO) Gyro_getADC(); else WMP_getRawADC();
    for (axis = 0; axis < 3; axis++)
      gyroADCp[axis] =  gyroADC[axis];
    timeInterleave=micros();
    annexCode();
    if ((micros()-timeInterleave)>650) {
       annex650_overrun_count++;
    } else {
       while((micros()-timeInterleave)<650) ; //empirical, interleaving delay between 2 consecutive reads
    }
    if (GYRO) Gyro_getADC(); else WMP_getRawADC();
    for (axis = 0; axis < 3; axis++) {
      gyroADCinter[axis] =  gyroADC[axis]+gyroADCp[axis];
      // empirical, we take a weighted value of the current and the previous values
      gyroData[axis] = (gyroADCinter[axis]+gyroADCprevious[axis]+1)/3;
      gyroADCprevious[axis] = gyroADCinter[axis]/2;
      if (!ACC) accADC[axis]=0;
    }
  }
  #if defined(TRI)
    gyroData[YAW] = (gyroYawSmooth*2+gyroData[YAW]+1)/3;
    gyroYawSmooth = gyroData[YAW];
  #endif
}

// **************************************************
// Simplified IMU based on "Complementary Filter"
// Inspired by http://starlino.com/imu_guide.html
//
// adapted by ziss_dm : http://wbb.multiwii.com/viewtopic.php?f=8&t=198
//
// The following ideas was used in this project:
// 1) Rotation matrix: http://en.wikipedia.org/wiki/Rotation_matrix
// 2) Small-angle approximation: http://en.wikipedia.org/wiki/Small-angle_approximation
// 3) C. Hastings approximation for atan2()
// 4) Optimization tricks: http://www.hackersdelight.org/
//
// Currently Magnetometer uses separate CF which is used only
// for heading approximation.
//
// Modified: 19/04/2011  by ziss_dm
// Version: V1.1
//
// code size deduction and tmp vector intermediate step for vector rotation computation: October 2011 by Alex
// **************************************************

//******  advanced users settings *******************
/* Set the Low Pass Filter factor for ACC */
/* Increasing this value would reduce ACC noise (visible in GUI), but would increase ACC lag time*/
/* Comment this if  you do not want filter at all.*/
/* Default WMC value: 8*/
#define ACC_LPF_FACTOR 8

/* Set the Low Pass Filter factor for Magnetometer */
/* Increasing this value would reduce Magnetometer noise (not visible in GUI), but would increase Magnetometer lag time*/
/* Comment this if  you do not want filter at all.*/
/* Default WMC value: n/a*/
#define MG_LPF_FACTOR 4

/* Set the Gyro Weight for Gyro/Acc complementary filter */
/* Increasing this value would reduce and delay Acc influence on the output of the filter*/
/* Default WMC value: 300*/
#define GYR_CMPF_FACTOR 500.0f

/* Set the Gyro Weight for Gyro/Magnetometer complementary filter */
/* Increasing this value would reduce and delay Magnetometer influence on the output of the filter*/
/* Default WMC value: n/a*/
#define GYR_CMPFM_FACTOR 500.0f

//****** end of advanced users settings *************

#define INV_GYR_CMPF_FACTOR   (1.0f / (GYR_CMPF_FACTOR  + 1.0f))
#define INV_GYR_CMPFM_FACTOR  (1.0f / (GYR_CMPFM_FACTOR + 1.0f))
#if GYRO
  #define GYRO_SCALE ((2380 * PI)/((32767.0f / 4.0f ) * 180.0f * 1000000.0f)) //should be 2279.44 but 2380 gives better result
  // +-2000/sec deg scale
  //#define GYRO_SCALE ((200.0f * PI)/((32768.0f / 5.0f / 4.0f ) * 180.0f * 1000000.0f) * 1.5f)     
  // +- 200/sec deg scale
  // 1.5 is emperical, not sure what it means
  // should be in rad/sec
#else
  #define GYRO_SCALE (1.0f/200e6f)
  // empirical, depends on WMP on IDG datasheet, tied of deg/ms sensibility
  // !!!!should be adjusted to the rad/sec
#endif 
// Small angle approximation
#define ssin(val) (val)
#define scos(val) 1.0f

typedef struct fp_vector {
  float X;
  float Y;
  float Z;
} t_fp_vector_def;

typedef union {
  float   A[3];
  t_fp_vector_def V;
} t_fp_vector;

int16_t _atan2(float y, float x){
  #define fp_is_neg(val) ((((byte*)&val)[3] & 0x80) != 0)
  float z = y / x;
  int16_t zi = abs(int16_t(z * 100)); 
  int8_t y_neg = fp_is_neg(y);
  if ( zi < 100 ){
    if (zi > 10) 
     z = z / (1.0f + 0.28f * z * z);
   if (fp_is_neg(x)) {
     if (y_neg) z -= PI;
     else z += PI;
   }
  } else {
   z = (PI / 2.0f) - z / (z * z + 0.28f);
   if (y_neg) z -= PI;
  }
  z *= (180.0f / PI * 10); 
  return z;
}

// Rotate Estimated vector(s) with small angle approximation, according to the gyro data
void rotateV(struct fp_vector *v,float* delta) {
  fp_vector v_tmp = *v;
  v->Z -= delta[ROLL]  * v_tmp.X + delta[PITCH] * v_tmp.Y;
  v->X += delta[ROLL]  * v_tmp.Z - delta[YAW]   * v_tmp.Y;
  v->Y += delta[PITCH] * v_tmp.Z + delta[YAW]   * v_tmp.X; 
}

// alexmos: need it later
static t_fp_vector EstG;
static float InvG = 255;

void getEstimatedAttitude(){
  uint8_t axis;
  int16_t accMag = 0;
#if MAG
  static t_fp_vector EstM;
#endif
#if defined(MG_LPF_FACTOR)
  static int16_t mgSmooth[3]; 
#endif
#if defined(ACC_LPF_FACTOR)
  static int16_t accTemp[3];  //projection of smoothed and normalized magnetic vector on x/y/z axis, as measured by magnetometer
#endif
  static uint16_t previousT;
  uint16_t currentT = micros();
  float scale, deltaGyroAngle[3];

  scale = (currentT - previousT) * GYRO_SCALE;
  previousT = currentT;

  // Initialization
  for (axis = 0; axis < 3; axis++) {
    deltaGyroAngle[axis] = gyroADC[axis]  * scale;
    #if defined(ACC_LPF_FACTOR)
      accTemp[axis] = (accTemp[axis] - (accTemp[axis] >>4)) + accADC[axis];
      accSmooth[axis] = accTemp[axis]>>4;
      #define ACC_VALUE accSmooth[axis]
    #else  
      accSmooth[axis] = accADC[axis];
      #define ACC_VALUE accADC[axis]
    #endif
    accMag += (ACC_VALUE * 10 / (int16_t)acc_1G) * (ACC_VALUE * 10 / (int16_t)acc_1G);
    #if MAG
      #if defined(MG_LPF_FACTOR)
        mgSmooth[axis] = (mgSmooth[axis] * (MG_LPF_FACTOR - 1) + magADC[axis]) / MG_LPF_FACTOR; // LPF for Magnetometer values
        #define MAG_VALUE mgSmooth[axis]
      #else  
        #define MAG_VALUE magADC[axis]
      #endif
    #endif
  }

  rotateV(&EstG.V,deltaGyroAngle);
  #if MAG
    rotateV(&EstM.V,deltaGyroAngle);
  #endif 

  if ( abs(accSmooth[ROLL])<acc_25deg && abs(accSmooth[PITCH])<acc_25deg && accSmooth[YAW]>0)
    smallAngle25 = 1;
  else
    smallAngle25 = 0;

  // Apply complimentary filter (Gyro drift correction)
  // If accel magnitude >1.4G or <0.6G and ACC vector outside of the limit range => we neutralize the effect of accelerometers in the angle estimation.
  // To do that, we just skip filter, as EstV already rotated by Gyro
  if ( ( 36 < accMag && accMag < 196 ) || smallAngle25 )
    for (axis = 0; axis < 3; axis++) {
      int16_t acc = ACC_VALUE;
      #if not defined(TRUSTED_ACCZ)
        if (smallAngle25 && axis == YAW)
          //We consider ACCZ = acc_1G when the acc on other axis is small.
          //It's a tweak to deal with some configs where ACC_Z tends to a value < acc_1G when high throttle is applied.
          //This tweak applies only when the multi is not in inverted position
          acc = acc_1G;      
      #endif
      EstG.A[axis] = (EstG.A[axis] * GYR_CMPF_FACTOR + acc) * INV_GYR_CMPF_FACTOR;
    }
  #if MAG
    for (axis = 0; axis < 3; axis++)
      EstM.A[axis] = (EstM.A[axis] * GYR_CMPFM_FACTOR  + MAG_VALUE) * INV_GYR_CMPFM_FACTOR;
  #endif
  
  // Attitude of the estimated vector
  angle[ROLL]  =  _atan2(EstG.V.X , EstG.V.Z) ;
  angle[PITCH] =  _atan2(EstG.V.Y , EstG.V.Z) ;
  #if MAG
    // Attitude of the cross product vector GxM
    heading = _atan2( EstG.V.X * EstM.V.Z - EstG.V.Z * EstM.V.X , EstG.V.Z * EstM.V.Y - EstG.V.Y * EstM.V.Z  ) / 10;
  #endif
  
  // alexmos: calc some useful values
  InvG = InvSqrt(fsq(EstG.V.X) + fsq(EstG.V.Y) + fsq(EstG.V.Z));
  #ifdef THROTTLE_ANGLE_CORRECTION
  	cosZ =  EstG.V.Z * InvG * 100; // cos(angleZ) * 100
  #endif
}


/* alexmos: baro + ACC altitude estimator */
/* It outputs altitude, velocity and 'pure' acceleration projected on Z axis (with 1G substracted) */
/* It has a very good resistance to inclanations, horisontal movements, ACC drift and baro noise. */
/* But it need fine tuning for various setups :( */
/* Settings: */
/* Set the ACC weight compared to BARO (or SONAR). Default is 100 */
#define ACC_BARO_CMPF 100.0f
/* Sensor PID values. */
/* Tuning advice: The main target is to get the minimum settle time of 'velocity' (it should fast go to zero without oscillations)  */
#define ACC_BARO_P 30.0f   
#define ACC_BARO_I 0.03f
#define ACC_BARO_D 0.03f


void getEstimatedAltitude(){
  static int8_t initDone = 0;
  static float alt = 0; // cm
  static float vel = 0; // cm/sec
 	static t_fp_vector errI = {0,0,0};
  static float accScale, velScale; // config variables
  float accZ, err, tmp;
  static int32_t avgError = 50, avgErrorFast = 0; 
  int16_t errA;
  int32_t sensorAlt;
  int8_t axis;
  int8_t sonarUsed;
  
  // get alt from sensors on sysem start
  if(!initDone) {
  	if(BaroAlt != 0) { // start only if any sensor data avaliable
		  #ifdef SONAR
	  		alt = SonarAlt;
		  	BaroSonarDiff = SonarAlt - BaroAlt;
		  #else
		  	alt = BaroAlt;
		  #endif
		  
	  	accScale = 9.80665f / acc_1G / 10000.0f;
	  	velScale = 1.0f/1000000.0f;
	  	errI.V.Z = get_accZ(&errI.V);
	  	initDone = 1;
	  }
	  return;
  }
  
  // If sonar present, it's altitude has more priority
  #ifdef SONAR
		// Use cross-section of SONAR and BARO altitudes, weighted by sonar erros
		sensorAlt = (SonarAlt * (SONAR_ERROR_MAX - SonarErrors) + (BaroAlt + BaroSonarDiff) * SonarErrors)/SONAR_ERROR_MAX;
		sonarUsed = SonarErrors < SONAR_ERROR_MAX ? 1 : 0;
  #else
  	sonarUsed = 0;
  	sensorAlt = BaroAlt;
  #endif

  
  // error between estimated alt and BARO alt
  errA = alt - sensorAlt;
  err = errA / ACC_BARO_CMPF;

  // Trust more ACC if in AltHold mode and sonar is not used and average error is low
	average(&avgErrorFast, errA, 100);
	average(&avgError, abs(avgErrorFast), 200); // double averge to prevent signed error cancellation
  if(baroMode && avgError < 5000 && sonarUsed == 0) { 
  	err/= (6 - avgError/1000); // CMPF multiplyer 1..5
  }
  
  // I term of error for each axis
  // (If Z angle is not zero, we should take X and Y axis into account and correct them too.
  // We will spread I error proportional to Cos(angle) for each axis
  // TODO: we got "real" ACC zero in this calibration procedure and may use it to correct ACC in angle estimation, too
  tmp = err*ACC_BARO_I*InvG;
  for(axis=0; axis<3; axis++) {
  	errI.A[axis]+= EstG.A[axis] * tmp; 
  }
  
  // Project ACC vector A to 'global' Z axis (estimated by gyro vector G) with I term taked into account
  // Math: accZ = (A + errI) * G / |G| - 1G
  accZ = get_accZ(&(errI.V));
  
  // Integrator - velocity, cm/sec
  // Apply P and D terms of PID correction
  // D term of real error is VERY noisy, so we use Dterm = vel*kd (it will lead velocity to zero)
  vel+= (accZ - err*ACC_BARO_P - vel*ACC_BARO_D) * cycleTime * accScale;
  
	// Integrator + apply ACC->BARO complementary filter
	alt+= vel * cycleTime * velScale - err;
  
  // Save global data for PID's
  EstAlt = alt;
  EstVelocity = vel;
  EstAcc = accZ;
  
  // debug to GUI
  #ifdef ALT_DEBUG
  	debug1 = sensorAlt;
	  debug2 = avgErrorFast;
	  debug3 = avgError/10;
	  //debug4 = errI.V.X;
	  heading = vel;
	#endif
}

// return projection of ACC vector to global Z, with 1G subtructed
float get_accZ(fp_vector *errI) {
	return ((accADC[0] - errI->X) * EstG.V.X + (accADC[1] - errI->Y) * EstG.V.Y + (accADC[2] - errI->Z) * EstG.V.Z) * InvG - acc_1G;
}

// average 'curVal' by 'factor'. Result multiplyed by 10 to increase store precision.
void average(int32_t *val, int16_t curVal, uint16_t factor) {
	*val = (*val*factor + curVal*10)/(factor+1);
}
	

int32_t isq(int32_t x){return x * x;}
float fsq(float x){return x * x;}

float InvSqrt (float x){ 
  union{  
    int32_t i;  
    float   f; 
  } conv; 
  conv.f = x; 
  conv.i = 0x5f3759df - (conv.i >> 1); 
  return 0.5f * conv.f * (3.0f - x * conv.f * conv.f);
} 

  
  
  
  
  
