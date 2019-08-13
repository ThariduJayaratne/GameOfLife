// COMS20001 - Cellular Automaton Farm
// (using the XMOS i2c accelerometer demo code)
#include <platform.h>
#include <xs1.h>
#include <stdio.h>
#include "pgmIO.h"
#include "i2c.h"

#define  IMHT 64                    //image height
#define  IMWD 64                   //image width
#define  nWorkers 8                //number of workers
#define  rounds 10000                   //number of rounds
#define  split (IMHT/nWorkers) + 2   //height of grid for each worker
char infname[] = "64x64.pgm";         //put your input image path here
char outfname[] = "testout.pgm";     //put your output image path here

typedef unsigned char uchar;        //using uchar as shorthand

on tile[0]: port p_scl = XS1_PORT_1E;         //interface ports to orientation
on tile[0]: port p_sda = XS1_PORT_1F;
on tile[0] : in port buttons = XS1_PORT_4E; //port to access xCore-200 buttons
on tile[0] : out port leds = XS1_PORT_4F;   //port to access xCore-200 LEDs

#define FXOS8700EQ_I2C_ADDR 0x1E  //register addresses for orientation
#define FXOS8700EQ_XYZ_DATA_CFG_REG 0x0E
#define FXOS8700EQ_CTRL_REG_1 0x2A
#define FXOS8700EQ_DR_STATUS 0x0
#define FXOS8700EQ_OUT_X_MSB 0x1
#define FXOS8700EQ_OUT_X_LSB 0x2
#define FXOS8700EQ_OUT_Y_MSB 0x3
#define FXOS8700EQ_OUT_Y_LSB 0x4
#define FXOS8700EQ_OUT_Z_MSB 0x5
#define FXOS8700EQ_OUT_Z_LSB 0x6

void showLEDs(out port p, chanend toDist) {
    int colour;
    while (1) {
       toDist :> colour;    // waiting to receive val from dist
       p <: colour;
    }
}

void buttonListener(in port x, chanend toDistributor){
    int dump;
    int pressed = 0;
    while (1) {
        if (!pressed) {
            x when pinseq(14) :> dump;
            pressed = !pressed;
            toDistributor <: 1;
        }
        x when pinseq(13) :> dump;
        toDistributor <: 1;
    }
}
void Timer(chanend toDist) {
    int dump;
    unsigned int start;
    unsigned int current;
    unsigned long finalTime = 0;
    unsigned int period = 100000;
    unsigned int maxTime = 1000000000;
    toDist :> dump;
    timer t;
    t :> start;
    printf("Timer started\n");
    while(1) {
        select {
            case t when timerafter (start + maxTime) :> void:
                    t :> start;
                    finalTime += 10000;
                    break;
            case toDist :> dump:
                t :> current;
                finalTime += (current - start)/period;
                printf("Game of Life processing time for %d rounds: %d ms\n", rounds, finalTime);
                break;
        }
    }
}

// Read Image from PGM file from path infname[] to channel c_out
void DataInStream(char infname[], chanend c_out) {
    int res;
    uchar line[ IMWD ];
    printf("DataInStream: Start...\n");

    //Open PGM file
    res = _openinpgm( infname, IMWD, IMHT );
    if( res ) {
        printf("DataInStream: Error openening %s\n.", infname);
        return;
    }

    //Read image line-by-line and send byte by byte to channel c_out
    for( int y = 0; y < IMHT; y++ ) {
        _readinline( line, IMWD );
        for( int x = 0; x < IMWD; x++ ) {
            c_out <: line[ x ];
            //printf( "-%4.1d ", line[ x ] ); //show image values
        }
       // printf( "\n" );
    }
    //Close PGM image file
    _closeinpgm();
    printf("DataInStream: Done...\n");
    return;
}

//Function for deciding if the pixel should be dead or alive
int rules(int g, int n) {
    int f = g;      //run through grid values and apply rules
    if (g == 255) {
        n -= 1;
        if (n < 2 || n > 3) f = 0;
    }
    else if (g == 0 && n == 3) f = 255;
    return f;
}

//Function for calculating number of live neighbour pixels
int friends(int y, int x, uchar grid[split][IMWD]) {//grid is split amongst workers by height
    int neighbours = 0;
    for (int i = y - 1; i <= y + 1; i++){  //checking up and down
        int col = (i + IMHT) % IMHT;
        for (int j = x - 1; j <= x + 1; j++) { // checking sideways
            int row = (j + IMWD) % IMWD;
            if (grid[col][row] == 255) neighbours += 1;
        }
    }
    return neighbours;
}

int liveCells(uchar grid[IMHT][IMWD]){
    int livecells = 0;
    for(int i=0;i<IMHT;i++){
        for(int j=0;j<IMWD;j++){
            if(grid[i][j]== 255){
                livecells++;
            }
        }
    }
    return livecells;
}

//Creates grid and distributes it to workers
void distributor(chanend c_in, chanend c_out, chanend fromAcc, chanend toWorker[nWorkers], chanend toButtonListener, chanend toTimer, chanend toLEDs) {
    uchar val;
    uchar grid[IMHT][IMWD];
    int tilted = 0;

    //Starting up and wait for button press
    printf( "ProcessImage: Start, size = %dx%d\n", IMHT, IMWD );
    printf( "Waiting for Button Press...\n" );
    toButtonListener :> int value;

    //Read in and create grid
    printf( "Processing...\n" );
    toLEDs <: 0b0100;
    for (int y = 0; y < IMHT; y++) {
        for (int x = 0; x < IMWD; x++) {
            c_in :> val;  //get the pixel value
            grid[y][x] = val; //create a grid
        }
    }
    toTimer <: 1;       //Initialises timer
    timer c;            //for pause
    unsigned int startT,stopT;
    c :> startT;
    const unsigned int pausePeriod = 100000;
    for(int a = 1; a <= rounds; a++){
        select{
            case fromAcc :> tilted:
                break;
            default:
                break;
        }
        if (a % 2 == 0) toLEDs <: 0b0000;
        else toLEDs <: 0b0001;
        //Send to workers
        for (int w = 0; w < nWorkers; w++) {
            int lowerBound = w*IMHT/nWorkers;
            for (int y = lowerBound - 1; y < lowerBound + IMHT/nWorkers + 1; y++) {//worker n gets n/TotalNoOfworkers of the grid and edge cases
                int col = (y + IMHT) % IMHT;
                for (int row = 0; row < IMWD; row++) {
                    toWorker[w] <: (uchar) grid[col][row];
                }
            }
        }
        //Recieve new grid from workers
        for (int w = 0; w < nWorkers; w++) {
            int lowerBound = w*IMHT/nWorkers;
            for (int y = lowerBound ; y < lowerBound + IMHT/nWorkers; y++) {
                for (int x = 0; x < IMWD; x++) { //go through each pixel per line
                    toWorker[w] :> grid[y][x];
                }
            } // prevents race condition
        }
        if(tilted){
            while(tilted){
                //time
                toLEDs <: 0b1000;
                c :> stopT;
                printf("Paused\n");
                printf("Rounds processed for now: %d\n",a);
                printf("Live cells: %d\n",liveCells(grid));
                printf("Time elapsed so far: %d ms\n",stopT/pausePeriod - startT/pausePeriod);
                fromAcc :> tilted;
                if(tilted == 0){
                    printf("Resuming\n");
                    break;
                }
            }
        }
        //printf("Round %d done\n", a);
    }
    toTimer <: 1; //Prints time
    printf("Processing completed...\n");
    printf("Ready to export, waiting for Button Press...\n");
    toButtonListener :> int value;
    toLEDs <: 0b0010;
    for (int y = 0; y < IMHT; y++) {
        for (int x = 0; x < IMWD; x++) {
            c_out <: (uchar) grid[y][x];
        }
    }
    toLEDs <: 0b0000;
}

void workers(int w, chanend toDist) {
    uchar grid[split][IMWD];
    uchar next[split][IMWD];

    while (1) {
        //Recieve grid from Distributor
        for (int y  = 0; y < split; y++) {
            for (int x = 0; x < IMWD; x++) {
                toDist :> grid[y][x];
            }
        }

        //Do some Game of Life
        for (int y = 1; y < split - 1; y++) { //remove two extra rows, the other workers are sending
            for (int x = 0; x < IMWD; x++) {
                int neighbours = friends(y, x, grid); //check 9 surrounding pixels
                next[y][x] = rules(grid[y][x], neighbours); //set next according to Game of Life rules
            }
        }

        //Send next grid to Distributor
        for (int y = 1; y < split - 1; y++) {
            for (int x = 0; x < IMWD; x++) {
                toDist <: (uchar) next[y][x];
            }
        }
    }
}

// Write pixel stream from channel c_in to PGM image file
void DataOutStream(char outfname[], chanend c_in) {
    int res;
    uchar line[ IMWD ];

    //Open PGM file
    printf( "DataOutStream: Start...\n" );
    res = _openoutpgm( outfname, IMWD, IMHT );
    if( res ) {
        printf( "DataOutStream: Error opening %s\n.", outfname );
        return;
    }
    //Compile each line of the image and write the image line-by-line
    for(int y = 0; y < IMHT; y++ ) {
        for (int x = 0; x < IMWD; x++ ) {
            c_in :> line[ x ];
        }
        _writeoutline( line, IMWD );
        printf( "DataOutStream: Line written...\n" );
    }

    //Close the PGM image
    _closeoutpgm();
    printf( "DataOutStream: Done...\n" );
    return;
}

// Initialise and  read orientation
void orientation( client interface i2c_master_if i2c, chanend toDist) {
    i2c_regop_res_t result;
    char status_data = 0;
    int tilted = 0;

    // Configure FXOS8700EQ
    result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_XYZ_DATA_CFG_REG, 0x01);
    if (result != I2C_REGOP_SUCCESS) {
        printf("I2C write reg failed\n");
    }

    // Enable FXOS8700EQ
    result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_CTRL_REG_1, 0x01);
    if (result != I2C_REGOP_SUCCESS) {
        printf("I2C write reg failed\n");
    }

    //Probe the orientation x-axis forever
    while (1) {

        //check until new orientation data is available
        do {
            status_data = i2c.read_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_DR_STATUS, result);
        } while (!status_data & 0x08);
        //get new x-axis tilt value
        int x = read_acceleration(i2c, FXOS8700EQ_OUT_X_MSB);
        //send signal to distributor after first tilt
        if (!tilted) {
            if (x>30) {
                tilted = 1 - tilted;
                toDist <: 1;
            }
        }
        else if(x<10){
            tilted = !tilted;
            toDist <: 0;
        }
    }
}

// Orchestrate concurrent system and start up all threads
int main(void) {
    i2c_master_if i2c[1];               //interface to orientation
    chan c_inIO, c_outIO, c_control, worker[nWorkers], c_fromDistToLeds, c_toButtonListener, c_timer;    //extend your channel definitions here

    par {
        on tile[0]: i2c_master(i2c, 1, p_scl, p_sda, 10);     //server thread providing orientation data
        on tile[0]: orientation(i2c[0],c_control);            //client thread reading orientation data
        on tile[0]: DataInStream(infname, c_inIO);            //thread to read in a PGM image
        on tile[0]: DataOutStream(outfname, c_outIO);         //thread to write out a PGM image
        on tile[0]: distributor(c_inIO, c_outIO, c_control, worker, c_toButtonListener, c_timer, c_fromDistToLeds);//thread to coordinate work on image
        on tile[0]: buttonListener(buttons, c_toButtonListener); //thread to read button presses
        on tile[0]: showLEDs(leds, c_fromDistToLeds);            //thread to configure LEDs
        on tile[0]: Timer(c_timer);                             //Timer?
        par (int w = 0; w < nWorkers; w++ ){
            on tile[1]: workers(w, worker[w]);                  //thread for each worker
        }
    }
    return 0;
}
