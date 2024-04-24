use anchor_lang::prelude::*;

declare_id!("GqcREMZ4UrdS6VwgVf3gnMV3iKYGbSoDVEuURjpgmvSG");

#[program]
pub mod gm_anchor {
    use super::*;

    pub fn gm_instruction(ctx: Context<GmAccounts>, gms: u8) -> Result<()> {

        msg!("signer signed is {}", ctx.accounts.signer.is_signer);

        require_gte!(10, gms, GmErrors::TooManyGMs);
        require!(gms <= 10, GmErrors::TooManyGMs);
        if gms > 10 {
            // return Err(error!(GmErrors::TooManyGMs));
            return err!(GmErrors::TooManyGMs);
        }
        msg!("GM!");
        if gms>1 {
            gm_instruction(ctx, gms-1)
        } else {
            Ok(())
        }
    }
    pub fn pseudo_gm_instruction(ctx: Context<PseudoGmAccounts>, number: u64) -> Result<()>{
        msg!("pseudo gm instruction");
        // let pseudo_account = &mut ctx.accounts.pseudo_account;
        // pseudo_account.number = number;
        // msg!("pseudo account number is {}", pseudo_account.number);
        Ok(())
    }
}

#[error_code]
pub enum GmErrors{
    #[msg("Too many GMs requested! Maximum is 10 GMs")]
    TooManyGMs

}

#[derive(Clone)]
pub struct GmProgram;

impl anchor_lang::Id for GmProgram {
    fn id() -> Pubkey {
        id()
    }
}

#[derive(Accounts)]
pub struct GmAccounts<'info> {

    /// CHECK: this is save, trust me, I'm a dev!
    pub signer: UncheckedAccount<'info>,
    pub gm_program: Program<'info, GmProgram>,
}

#[derive(Accounts)]
pub struct PseudoGmAccounts<'info>{

    pub pseudo_account: Account<'info, PeSudoAccount >,
    /// CHECK: using test
    pub signer: UncheckedAccount<'info>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub gm_program: Program<'info, GmProgram>,
    pub system_program: Program<'info, System>,
}

#[account]
pub struct  PeSudoAccount{
    pub number: u64
}
