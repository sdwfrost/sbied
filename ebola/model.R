## ----prelims,include=FALSE,cache=FALSE-----------------------------------
options(
  keep.source=TRUE,
  stringsAsFactors=FALSE,
  encoding="UTF-8"
  )

set.seed(594709947L)
library(ggplot2)
theme_set(theme_bw())
library(plyr)
library(reshape2)
library(magrittr)
library(pomp)
stopifnot(packageVersion("pomp")>="1.6")

## ----get-data,include=FALSE----------------------------------------------
base_url <- "http://kingaa.github.io/sbied/"
read.csv(paste0(base_url,"ebola/ebola_data.csv"),stringsAsFactors=FALSE,
         colClasses=c(date="Date")) -> dat
sapply(dat,class)
head(dat)

## ----popsizes,include=FALSE----------------------------------------------
populations <- c(Guinea=10628972,Liberia=4092310,SierraLeone=6190280)

## ----plot-data,echo=FALSE------------------------------------------------
dat %>%
  ggplot(aes(x=date,y=cases,group=country,color=country))+
  geom_line()

## ----rproc,include=FALSE-------------------------------------------------
rSim <- Csnippet('
  double lambda, beta;
  double *E = &E1;
  beta = R0 * gamma; // Transmission rate
  lambda = beta * I / N; // Force of infection
  int i;

  // Transitions
  // From class S
  double transS = rbinom(S, 1.0 - exp(- lambda * dt)); // No of infections
  // From class E
  double transE[nstageE]; // No of transitions between classes E
  for(i = 0; i < nstageE; i++){
    transE[i] = rbinom(E[i], 1.0 - exp(-nstageE * alpha * dt));
  }
  // From class I
  double transI = rbinom(I, 1.0 - exp(-gamma * dt)); // No of transitions I->R

  // Balance the equations
  S -= transS;
  E[0] += transS - transE[0];
  for(i=1; i < nstageE; i++) {
    E[i] += transE[i-1] - transE[i];
  }
  I += transE[nstageE-1] - transI;
  R += transI;
  N_EI += transE[nstageE-1]; // No of transitions from E to I
  N_IR += transI; // No of transitions from I to R
')

rInit <- Csnippet("
  double m = N/(S_0+E_0+I_0+R_0);
  double *E = &E1;
  int j;
  S = nearbyint(m*S_0);
  for (j = 0; j < nstageE; j++) E[j] = nearbyint(m*E_0/nstageE);
  I = nearbyint(m*I_0);
  R = nearbyint(m*R_0);
  N_EI = 0;
  N_IR = 0;
")

## ----skel,include=FALSE--------------------------------------------------
skel <- Csnippet('
  double lambda, beta;
  const double *E = &E1;
  double *DE = &DE1;
  beta = R0 * gamma; // Transmission rate
  lambda = beta * I / N; // Force of infection
  int i;

  // Balance the equations
  DS = - lambda * S;
  DE[0] = lambda * S - nstageE * alpha * E[0];
  for (i=1; i < nstageE; i++)
    DE[i] = nstageE * alpha * (E[i-1]-E[i]);
  DI = nstageE * alpha * E[nstageE-1] - gamma * I;
  DR = gamma * I;
  DN_EI = nstageE * alpha * E[nstageE-1];
  DN_IR = gamma * I;
')

## ----measmodel,include=FALSE---------------------------------------------
dObs <- Csnippet('
  double f;
  if (k > 0.0)
    f = dnbinom_mu(nearbyint(cases),1.0/k,rho*N_EI,1);
  else
    f = dpois(nearbyint(cases),rho*N_EI,1);
  lik = (give_log) ? f : exp(f);
')

rObs <- Csnippet('
  if (k > 0) {
    cases = rnbinom_mu(1.0/k,rho*N_EI);
  } else {
    cases = rpois(rho*N_EI);
  }')

## ----partrans,include=FALSE----------------------------------------------
toEst <- Csnippet('
  const double *IC = &S_0;
  double *TIC = &TS_0;
  TR0 = log(R0);
  Trho = logit(rho);
  Tk = log(k);
  to_log_barycentric(TIC,IC,4);
')

fromEst <- Csnippet('
  const double *IC = &S_0;
  double *TIC = &TS_0;
  TR0 = exp(R0);
  Trho = expit(rho);
  Tk = exp(k);
  from_log_barycentric(TIC,IC,4);
')

## ----pomp-construction,include=FALSE-------------------------------------
ebolaModel <- function (country=c("Guinea", "SierraLeone", "Liberia"),
                        timestep = 0.1, nstageE = 3) {

  ctry <- match.arg(country)
  pop <- unname(populations[ctry])
  nstageE <- as.integer(nstageE)

  globs <- paste0("static int nstageE = ",nstageE,";")

  dat <- subset(dat,country==ctry,select=-country)

  ## Create the pomp object
  dat %>% 
    extract(c("week","cases")) %>%
    pomp(
      times="week",
      t0=min(dat$week)-1,
      globals=globs,
      statenames=c("S",sprintf("E%1d",seq_len(nstageE)),
                   "I","R","N_EI","N_IR"),
      zeronames=c("N_EI","N_IR"),
      paramnames=c("N","R0","alpha","gamma","rho","k",
                   "S_0","E_0","I_0","R_0"),
      dmeasure=dObs, rmeasure=rObs,
      rprocess=discrete.time.sim(step.fun=rSim, delta.t=timestep),
      skeleton=vectorfield(skel),
      toEstimationScale=toEst,
      fromEstimationScale=fromEst,
      initializer=rInit) -> po
}

ebolaModel("Guinea") -> gin
ebolaModel("SierraLeone") -> sle
ebolaModel("Liberia") -> lbr

## ----load-profile,echo=FALSE---------------------------------------------
options(stringsAsFactors=FALSE)
profs <- read.csv(paste0(base_url,"/ebola/ebola-profiles.csv"))

## ----profiles-plots,results='hide',echo=FALSE----------------------------
library(reshape2)
library(plyr)
library(magrittr)
library(ggplot2)
theme_set(theme_bw())

profs %>% 
  melt(id=c("profile","country","loglik")) %>%
  subset(variable==profile) %>%
  ddply(~country,mutate,dll=loglik-max(loglik)) %>%
  ddply(~country+profile+value,subset,loglik==max(loglik)) %>% 
  ggplot(mapping=aes(x=value,y=dll))+
  geom_point(color='red')+
  geom_hline(yintercept=-0.5*qchisq(p=0.99,df=1))+
  facet_grid(country~profile,scales='free')+
  labs(y=expression(l))

## ----diagnostics1,echo=FALSE---------------------------------------------
library(pomp)
library(plyr)
library(reshape2)
library(magrittr)
options(stringsAsFactors=FALSE)

profs %>%
  subset(country=="Guinea") %>%
  subset(loglik==max(loglik),
         select=-c(loglik,loglik.se,country,profile)) %>%
  unlist() -> coef(gin)

simulate(gin,nsim=20,as.data.frame=TRUE,include.data=TRUE) %>% 
  mutate(date=min(dat$date)+7*(time-1),
         is.data=ifelse(sim=="data","yes","no")) %>% 
  ggplot(aes(x=date,y=cases,group=sim,color=is.data,
         alpha=is.data))+
  geom_line()+
  guides(color=FALSE,alpha=FALSE)+
  scale_color_manual(values=c(no=gray(0.6),yes='red'))+
  scale_alpha_manual(values=c(no=0.5,yes=1))

## ----diagnostics-growth-rate---------------------------------------------
growth.rate <- function (y) {
  cases <- y["cases",]
  fit <- lm(log1p(cases)~seq_along(cases))
  unname(coef(fit)[2])
}
probe(gin,probes=list(r=growth.rate),nsim=500) %>% plot()

## ----diagnostics-growth-rate-and-sd--------------------------------------
growth.rate.plus <- function (y) {
  cases <- y["cases",]
  fit <- lm(log1p(cases)~seq_along(cases))
  c(r=unname(coef(fit)[2]),sd=sd(residuals(fit)))
}
probe(gin,probes=list(growth.rate.plus),
      nsim=500) %>% plot()

## ----diagnostics2,fig.height=6-------------------------------------------
log1p.detrend <- function (y) {
  cases <- y["cases",]
  y["cases",] <- as.numeric(residuals(lm(log1p(cases)~seq_along(cases))))
  y
}

probe(gin,probes=list(
  growth.rate.plus,
  probe.quantile(var="cases",prob=c(0.25,0.75)),
  probe.acf(var="cases",lags=c(1,2,3),type="correlation",
            transform=log1p.detrend)
),nsim=500) %>% plot()

## ----forecasts1----------------------------------------------------------
library(pomp)
library(plyr)
library(reshape2)
library(magrittr)
options(stringsAsFactors=FALSE)

set.seed(988077383L)

## forecast horizon
horizon <- 13

## Weighted quantile function
wquant <- function (x, weights, probs = c(0.025,0.5,0.975)) {
  idx <- order(x)
  x <- x[idx]
  weights <- weights[idx]
  w <- cumsum(weights)/sum(weights)
  rval <- approx(w,x,probs,rule=1)
  rval$y
}

profs %>% 
  subset(country=="SierraLeone",
         select=-c(country,profile,loglik.se)) %>%
  subset(loglik>max(loglik)-0.5*qchisq(df=1,p=0.99)) %>%
  melt(variable.name="parameter") %>%
  ddply(~parameter,summarize,
        min=min(value),max=max(value)) %>%
  subset(parameter!="loglik") %>%
  melt(measure=c("min","max")) %>%
  acast(parameter~variable) -> ranges

params <- sobolDesign(lower=ranges[,'min'],
                      upper=ranges[,'max'],
                      nseq=20)
plot(params)

## ----forecasts2----------------------------------------------------------
library(foreach)
library(doParallel)
library(iterators)

registerDoParallel()

set.seed(887851050L,kind="L'Ecuyer")

foreach(p=iter(params,by='row'),
        .inorder=FALSE,
        .combine=rbind,
        .options.multicore=list(preschedule=TRUE,set.seed=TRUE)
        ) %dopar%
    {
        library(pomp)
        
        M1 <- ebolaModel("SierraLeone")

        pf <- pfilter(M1,params=unlist(p),Np=2000,save.states=TRUE)

        pf$saved.states %>%                 # latent state for each particle
            tail(1) %>%                     # last timepoint only
            melt() %>%                      # reshape and rename the state variables
            dcast(rep~variable,value.var="value") %>%
            ddply(~rep,summarize,S_0=S,E_0=E1+E2+E3,I_0=I,R_0=R) %>%
            melt(id="rep") %>%
            acast(variable~rep) -> x
        ## the final states are now stored in 'x' as initial conditions
        
        ## set up a matrix of parameters
        pp <- parmat(unlist(p),ncol(x)) 
        
        ## generate simulations over the interval for which we have data
        simulate(M1,params=pp,obs=TRUE) %>%
            melt() %>%
            mutate(time=time(M1)[time],
                   period="calibration",
                   loglik=logLik(pf)) -> calib

        ## make a new 'pomp' object for the forecast simulations
        M2 <- M1
        time(M2) <- max(time(M1))+seq_len(horizon)
        timezero(M2) <- max(time(M1))
        
        ## set the initial conditions to the final states computed above
        pp[rownames(x),] <- x
        
        ## perform forecast simulations
        simulate(M2,params=pp,obs=TRUE) %>%
            melt() %>%
            mutate(time=time(M2)[time],
                   period="projection",
                   loglik=logLik(pf)) -> proj
        
        rbind(calib,proj)
    } %>%
    subset(variable=="cases",select=-variable) %>%
    mutate(weight=exp(loglik-mean(loglik))) %>%
    arrange(time,rep) -> sims

## look at effective sample size
ess <- with(subset(sims,time==max(time)),weight/sum(weight))
ess <- 1/sum(ess^2); ess

## compute quantiles of the forecast incidence
sims %>%
    ddply(~time+period,summarize,prob=c(0.025,0.5,0.975),
          quantile=wquant(value,weights=weight,probs=prob)) %>%
    mutate(prob=mapvalues(prob,from=c(0.025,0.5,0.975),
                          to=c("lower","median","upper"))) %>%
    dcast(period+time~prob,value.var='quantile') %>%
    mutate(date=min(dat$date)+7*(time-1)) -> simq

## ----forecast-plots,echo=FALSE-------------------------------------------
simq %>% ggplot(aes(x=date))+
  geom_ribbon(aes(ymin=lower,ymax=upper,fill=period),alpha=0.3,color=NA)+
  geom_line(aes(y=median,color=period))+
  geom_point(data=subset(dat,country=="SierraLeone"),
             mapping=aes(x=date,y=cases),color='black')+
  labs(y="cases")

